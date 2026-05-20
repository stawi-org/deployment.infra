# Split cluster DNS into 04-dns — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `prod.<zone>` LB round-robin DNS out of `03-talos` into a new `04-dns` layer running in parallel with `04-flux`. A CF DNS drift failure must not fail Talos config apply.

**Architecture:** Single new tofu layer at `tofu/layers/04-dns/` (sibling to `04-flux`). Reads infra remote states directly. Lifts the existing `03-talos/dns.tf` drift self-heal verbatim. Departs `03-talos`'s state via `removed { destroy = false }`. Adds whitelist-scoped stale-record cleanup, `create_before_destroy` on `cloudflare_dns_record`, and a CI drift-summary annotation.

**Tech Stack:** OpenTofu ≥ 1.10, Cloudflare provider 5.x, aws (R2 backend) provider 5.70.x, GitHub Actions reusable workflow `.github/workflows/tofu-layer.yml`.

**Spec:** `docs/superpowers/specs/2026-05-20-dns-layer-split-design.md`

---

## File map

**Create:**
- `tofu/layers/04-dns/backend.tf`
- `tofu/layers/04-dns/versions.tf`
- `tofu/layers/04-dns/variables.tf`
- `tofu/layers/04-dns/main.tf`
- `tofu/layers/04-dns/dns.tf`
- `tofu/layers/04-dns/terraform.tfvars` (symlink to shared)
- `tofu/layers/04-dns/versions.auto.tfvars.json` (symlink to shared)
- `tofu/layers/03-talos/removed.tf` (transitional; deleted in follow-up)

Stale-record cleanup is deferred per the spec — implementing it correctly needs a 2-PR adopt-then-remove sequence; tracked as follow-up.

**Modify:**
- `tofu/modules/cloudflare-dns/main.tf` (add `lifecycle { create_before_destroy = true }` to `cloudflare_dns_record.this`)
- `tofu/layers/03-talos/versions.tf` (remove `cloudflare` provider block + `cloudflare` from `required_providers`)
- `tofu/layers/03-talos/variables.tf` (remove `cloudflare_api_token` and `cp_dns_zones` variables)
- `.github/workflows/tofu-apply.yml` (add `dns` job, mirror of `flux`)
- `.github/workflows/tofu-plan.yml` (add `dns` job)
- `.github/workflows/tofu-layer.yml` (add layer-04-dns-specific drift-summary step)

**Delete:**
- `tofu/layers/03-talos/dns.tf`

---

## Task 1: Scaffold empty 04-dns layer

**Goal:** A layer that initialises and validates but does nothing yet.

**Files:**
- Create: `tofu/layers/04-dns/backend.tf`
- Create: `tofu/layers/04-dns/versions.tf`
- Create: `tofu/layers/04-dns/variables.tf`
- Create: `tofu/layers/04-dns/main.tf`

- [ ] **Step 0: Create the feature branch (one-time, before Task 1's other steps)**

```bash
git checkout main
git pull --ff-only
git checkout -b dns-layer-split
```

- [ ] **Step 1: Create `backend.tf`**

```hcl
# tofu/layers/04-dns/backend.tf
terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
    key                         = "production/04-dns.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = true
    encrypt                     = true
  }
}
```

- [ ] **Step 2: Create `versions.tf`**

```hcl
# tofu/layers/04-dns/versions.tf
#
# DNS-only layer. Reads node IPs from upstream infra layer tfstates and
# writes A/AAAA records to Cloudflare. Carved out of 03-talos in
# 2026-05 (spec: docs/superpowers/specs/2026-05-20-dns-layer-split-design.md)
# so a CF API failure no longer blocks Talos machine-config apply.
terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# AWS provider points at Cloudflare R2 — required because the
# terraform_remote_state readers in main.tf use the s3 backend against
# R2's S3-compatible endpoint.
provider "aws" {
  region                      = "auto"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  endpoints {
    s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  }
}
```

- [ ] **Step 3: Create `variables.tf`**

```hcl
# tofu/layers/04-dns/variables.tf
variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID. Used to construct the S3-compatible endpoint for cross-layer terraform_remote_state reads."
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:DNS:Edit on every zone listed in cp_dns_zones. Supplied via TF_VAR_cloudflare_api_token from the CLOUDFLARE_API_TOKEN GitHub Actions secret."
}

variable "cp_dns_zones" {
  type = list(object({
    zone       = string
    zone_id    = string
    prod_label = optional(string, "prod")
  }))
  default     = []
  description = <<-EOT
    Cloudflare zones to publish cluster DNS into, computed from every
    load-balancer node across every provider (Contabo + OCI + on-prem).

    Per zone:
      - <prod_label>.<zone>  round-robin A/AAAA across nodes carrying
                             node.kubernetes.io/external-load-balancer="true";
                             omitted when no nodes match

    Default: prod_label="prod".

    The bare `cp.<zone>` round-robin is owned by the 00-omni-server
    layer (it points at the Omni dashboard host, orange-cloud) — this
    layer does not publish it.

    zone_id is passed directly (no Cloudflare API lookup), so a token
    scoped only to Zone:DNS:Edit is sufficient.
  EOT
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Required by the SOPS health-check fixture in sops-check.tf."
}

variable "ci_run_id" {
  type        = string
  default     = "local"
  description = "Set by CI to $GITHUB_RUN_ID; surfaced in any artifact metadata this layer emits."
}
```

- [ ] **Step 4: Create `main.tf` — cross-layer state reads**

```hcl
# tofu/layers/04-dns/main.tf
#
# Reads each upstream infra layer's `nodes` output across every
# account (Contabo + Oracle + on-prem), folds them into one map keyed
# by globally-unique node name, then feeds the LB-tagged subset into
# dns.tf which publishes prod.<zone> round-robin records.
#
# Identical state-read shape to 03-talos/main.tf lines 20-95 — DNS
# does not depend on 03-talos's tfstate so a talos apply failure
# does not block this layer.

data "terraform_remote_state" "contabo" {
  for_each = toset(yamldecode(file("${path.module}/../../shared/accounts.yaml")).contabo)
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/01-contabo-infra-${each.key}.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

data "terraform_remote_state" "oracle" {
  for_each = toset(yamldecode(file("${path.module}/../../shared/accounts.yaml")).oracle)
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-oracle-infra-${each.key}.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

data "terraform_remote_state" "onprem" {
  for_each = toset(yamldecode(file("${path.module}/../../shared/accounts.yaml")).onprem)
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-onprem-infra-${each.key}.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

locals {
  contabo_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.contabo :
    try(s.outputs.nodes, {})
  ]...)
  oracle_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.oracle :
    try(s.outputs.nodes, {})
  ]...)
  onprem_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.onprem :
    try(s.outputs.nodes, {})
  ]...)

  # All nodes across providers — the input set for the LB filter in
  # dns.tf. Same shape as 03-talos's local.all_nodes_from_state.
  all_nodes_from_state = merge(
    local.contabo_outputs_nodes,
    local.oracle_outputs_nodes,
    local.onprem_outputs_nodes,
  )
}
```

- [ ] **Step 5: Create symlinks for shared tfvars**

```bash
cd tofu/layers/04-dns
ln -s ../../shared/terraform.tfvars terraform.tfvars
ln -s ../../shared/versions.auto.tfvars.json versions.auto.tfvars.json
cd -
```

Verify both symlinks resolve:

```bash
test -L tofu/layers/04-dns/terraform.tfvars && readlink tofu/layers/04-dns/terraform.tfvars
test -L tofu/layers/04-dns/versions.auto.tfvars.json && readlink tofu/layers/04-dns/versions.auto.tfvars.json
```

Expected: both print `../../shared/<filename>`.

- [ ] **Step 6: Run `tofu init -backend=false` + `tofu validate`**

```bash
cd tofu/layers/04-dns
tofu init -backend=false
tofu validate
cd -
```

Expected output ends with `Success! The configuration is valid.`

If validate fails: re-read variables.tf and main.tf for typos.

- [ ] **Step 7: Commit**

```bash
git add tofu/layers/04-dns/backend.tf tofu/layers/04-dns/versions.tf tofu/layers/04-dns/variables.tf tofu/layers/04-dns/main.tf tofu/layers/04-dns/terraform.tfvars tofu/layers/04-dns/versions.auto.tfvars.json
git commit -m "04-dns: scaffold empty layer (state reads only, no resources yet)"
```

---

## Task 2: Add `create_before_destroy` to the shared cloudflare-dns module

**Goal:** IP changes go (create new) → (delete old) instead of (delete) → (create), avoiding a brief NXDOMAIN. Module is used by both `00-omni-server` (via `cloudflare_dns_record` resources defined directly) and `04-dns` (after Task 3). The `00-omni-server` resources are declared outside this module and remain untouched.

**Files:**
- Modify: `tofu/modules/cloudflare-dns/main.tf:23-32`

- [ ] **Step 1: Edit `tofu/modules/cloudflare-dns/main.tf` — add `lifecycle` block to `cloudflare_dns_record.this`**

Find this block in `tofu/modules/cloudflare-dns/main.tf`:

```hcl
resource "cloudflare_dns_record" "this" {
  for_each = local.flat

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = var.ttl
  proxied = var.proxied
}
```

Replace with:

```hcl
resource "cloudflare_dns_record" "this" {
  for_each = local.flat

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = var.ttl
  proxied = var.proxied

  # An IP change to a managed name (e.g. LB worker re-IP) becomes
  # (create new) → (delete old) instead of (delete) → (create). The
  # old record stays resolvable until the new one is created, so a
  # public client never sees NXDOMAIN during the swap.
  lifecycle {
    create_before_destroy = true
  }
}
```

- [ ] **Step 2: Validate the module's only caller still parses (00-omni-server uses raw `cloudflare_dns_record`, not this module — sanity-check anyway)**

```bash
cd tofu/layers/00-omni-server
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

```bash
cd tofu/layers/03-talos
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: Commit**

```bash
git add tofu/modules/cloudflare-dns/main.tf
git commit -m "cloudflare-dns: add create_before_destroy to avoid NXDOMAIN on IP change"
```

---

## Task 3: Lift `dns.tf` from 03-talos into 04-dns

**Goal:** Move the LB filter + drift-self-heal verbatim into the new layer. Behaviour-preserving: locals reference `local.all_nodes_from_state` which exists with identical shape in both layers (Task 1 main.tf wrote it).

**Files:**
- Create: `tofu/layers/04-dns/dns.tf`

- [ ] **Step 1: Create `tofu/layers/04-dns/dns.tf` by copying `tofu/layers/03-talos/dns.tf` verbatim**

```bash
cp tofu/layers/03-talos/dns.tf tofu/layers/04-dns/dns.tf
```

- [ ] **Step 2: Update the header comment in the new file to reflect the move**

Open `tofu/layers/04-dns/dns.tf` and replace the comment block at lines 1-21 with:

```hcl
# tofu/layers/04-dns/dns.tf
#
# Cross-provider cluster DNS — publishes the public-load-balancer
# round-robin only.
#
#   prod.<zone>      A/AAAA across every node carrying
#                    `node.kubernetes.io/external-load-balancer="true"`.
#                    Frontends ingress traffic into the cluster. The
#                    LB itself terminates TLS via cert-manager inside
#                    the cluster, so this record is plain DNS-only.
#
# Per-CP `cp-<N>.<zone>` records were dropped in 2026-04 along with
# the rest of the talosctl-bootstrap path — the cluster's k8s API
# is reached via Omni's k8s-proxy at `cp.<zone>` (owned by the
# 00-omni-server layer, orange-cloud).
#
# Runs in 04-dns (carved out of 03-talos in 2026-05) so a Cloudflare
# API failure no longer blocks Talos config apply. LB nodes can come
# from any provider; this layer reads contabo/oracle/onprem remote
# states directly (see main.tf).
```

Leave lines 22-182 (the actual logic) unchanged — `lb_nodes`, `cluster_dns_records_per_zone`, `module "cluster_dns"`, the drift-self-heal data source + import block, and the `_debug_dns_*` outputs all carry over verbatim.

- [ ] **Step 3: Run `tofu validate` against 04-dns**

```bash
cd tofu/layers/04-dns
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

If validate fails citing an undeclared reference: check `local.all_nodes_from_state` shape against the references in the lifted dns.tf — they should both expose `derived_labels`, `ipv4`, `ipv6` at the same nesting.

- [ ] **Step 4: Commit**

```bash
git add tofu/layers/04-dns/dns.tf
git commit -m "04-dns: lift dns.tf from 03-talos (LB round-robin + drift self-heal)"
```

---

## Task 4: Add CI drift-summary step to `tofu-layer.yml`

**Goal:** Operators see a GitHub annotation listing intended changes ("create 3, import 2, destroy 0") before merging — specifically for the `04-dns` layer where DNS surprises are highest-impact.

**Files:**
- Modify: `.github/workflows/tofu-layer.yml` (after the existing "Render plan.json for regression check" step around line 526-533)

- [ ] **Step 1: Locate the existing plan.json render step**

Run:

```bash
grep -n "Render plan.json" .github/workflows/tofu-layer.yml
```

Expected: line 526 (approximately).

- [ ] **Step 2: Add a new step IMMEDIATELY after the plan.json render step**

Open `.github/workflows/tofu-layer.yml`. Find the step:

```yaml
      - name: Render plan.json for regression check
        if: inputs.mode == 'plan' || inputs.mode == 'apply'
        # ...
        run: tofu show -json tfplan > plan.json
```

Add this step directly below it:

```yaml
      - name: Summarise non-no-op changes (04-dns only)
        # Only surface for layers where DNS surprises are highest-impact.
        # Other layers already emit their own structured plan logs.
        if: |
          (inputs.mode == 'plan' || inputs.mode == 'apply')
          && inputs.layer == '04-dns'
        working-directory: tofu/layers/${{ inputs.layer }}
        env:
          LAYER: ${{ inputs.layer }}
        run: |
          set -euo pipefail
          if [[ ! -f plan.json ]]; then
            echo "::warning::plan.json missing for $LAYER — skipping change summary"
            exit 0
          fi
          changes=$(jq '[.resource_changes[]
                          | select(.change.actions[] != "no-op")
                          | {address, actions: .change.actions, type}]' plan.json)
          count=$(jq 'length' <<<"$changes")
          if [[ "$count" == "0" ]]; then
            echo "::notice::${LAYER} plan: no DNS changes"
            exit 0
          fi
          created=$(jq '[.[] | select(.actions[] == "create")] | length' <<<"$changes")
          updated=$(jq '[.[] | select(.actions[] == "update")] | length' <<<"$changes")
          destroyed=$(jq '[.[] | select(.actions[] == "delete")] | length' <<<"$changes")
          replaced=$(jq '[.[] | select((.actions[] == "delete") and (.actions[] == "create"))] | length' <<<"$changes")
          echo "::notice::${LAYER} plan: create=$created update=$updated destroy=$destroyed replace=$replaced"
          jq -r '.[] | "  • \(.address): \(.actions | join(","))"' <<<"$changes" | head -50
```

- [ ] **Step 3: Validate workflow YAML parses**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/tofu-layer.yml'))" && echo "OK"
```

Expected: `OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/tofu-layer.yml
git commit -m "tofu-layer: emit per-resource change annotation for 04-dns plans"
```

---

## Task 5: Wire `04-dns` jobs into `tofu-plan.yml` and `tofu-apply.yml`

**Goal:** `04-dns` runs after `03-talos` (sequence) but doesn't read `03-talos`'s outputs (independence). Parallel with `04-flux`.

**Files:**
- Modify: `.github/workflows/tofu-plan.yml` (add `dns` plan job after `talos`)
- Modify: `.github/workflows/tofu-apply.yml` (add `dns` apply job after `talos`)

- [ ] **Step 1: Add `dns` job to `tofu-plan.yml`**

Open `.github/workflows/tofu-plan.yml`. Find the `talos` job (around line 130). Add the following job IMMEDIATELY after the `talos` job and BEFORE the existing `flux` job:

```yaml
  dns:
    needs: talos
    permissions:
      contents: read
      id-token: write
      pull-requests: write
    # DNS apply is independent of talos config apply success — a talos
    # failure does not block DNS reconciliation. Same != 'cancelled'
    # gate as talos to keep the plan running through transient failures.
    if: always() && needs.talos.result != 'cancelled'
    uses: ./.github/workflows/tofu-layer.yml
    with: { layer: 04-dns, mode: plan }
    secrets: inherit
```

- [ ] **Step 2: Add `dns` job to `tofu-apply.yml`**

Open `.github/workflows/tofu-apply.yml`. Find the `talos` job (around line 188-220) and the gated-off `flux` job below it (around line 227-239). Add this job between them:

```yaml
  dns:
    # DNS apply is independent of talos config apply success — a talos
    # failure does not block DNS reconciliation. The 04-dns layer reads
    # infra remote states directly, not 03-talos's state, so a stale
    # 03-talos state has no effect.
    needs: talos
    if: always() && needs.talos.result != 'cancelled'
    permissions:
      contents: read
      id-token: write
      pull-requests: write
    uses: ./.github/workflows/tofu-layer.yml
    with:
      layer: 04-dns
      mode: apply
      environment: production
    secrets: inherit
```

- [ ] **Step 3: Validate both workflow YAMLs parse**

```bash
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/tofu-plan.yml'))" && echo "tofu-plan OK"
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/tofu-apply.yml'))" && echo "tofu-apply OK"
```

Expected: both print `... OK`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/tofu-plan.yml .github/workflows/tofu-apply.yml
git commit -m "tofu-{plan,apply}: add 04-dns job (depends on talos, isolated failure)"
```

---

## Task 6: Remove DNS from 03-talos via `removed { destroy = false }`

**Goal:** Drop `module.cluster_dns` from `03-talos`'s tfstate without making any Cloudflare API calls. The records remain in CF for `04-dns` to adopt via its import block on the first 04-dns apply.

**Files:**
- Create: `tofu/layers/03-talos/removed.tf` (transitional)
- Delete: `tofu/layers/03-talos/dns.tf`
- Modify: `tofu/layers/03-talos/versions.tf` (remove `cloudflare` from `required_providers` + provider block)
- Modify: `tofu/layers/03-talos/variables.tf` (remove `cloudflare_api_token` and `cp_dns_zones`)

- [ ] **Step 1: Create the transitional `removed` block file**

Create `tofu/layers/03-talos/removed.tf`:

```hcl
# tofu/layers/03-talos/removed.tf
#
# TRANSITIONAL — delete after the first successful 03-talos apply.
#
# DNS was split out of this layer into 04-dns (2026-05; spec:
# docs/superpowers/specs/2026-05-20-dns-layer-split-design.md). The
# `module.cluster_dns` resources need to leave 03-talos's tfstate
# WITHOUT being destroyed in Cloudflare — 04-dns's import block
# adopts them on its first apply.
#
# `lifecycle.destroy = false` means tofu plans a state-only removal
# (no provider API call). After this commit's 03-talos apply
# completes, the cluster_dns module is no longer in 03-talos's
# tfstate, and this file can be deleted in a follow-up commit.
removed {
  from = module.cluster_dns
  lifecycle {
    destroy = false
  }
}
```

- [ ] **Step 2: Delete `tofu/layers/03-talos/dns.tf`**

```bash
git rm tofu/layers/03-talos/dns.tf
```

- [ ] **Step 3: Edit `tofu/layers/03-talos/versions.tf` — remove `cloudflare` provider**

Open `tofu/layers/03-talos/versions.tf`. Find this block:

```hcl
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
```

Delete those four lines from `required_providers`.

Then find this block lower in the file:

```hcl
provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
```

Delete those three lines.

- [ ] **Step 4: Edit `tofu/layers/03-talos/variables.tf` — remove `cloudflare_api_token` and `cp_dns_zones`**

Open `tofu/layers/03-talos/variables.tf`. Delete the entire `variable "cloudflare_api_token"` block (lines 31-35) and the entire `variable "cp_dns_zones"` block (lines 37-65 approximately — the block ends at the closing `}` after the `EOT` heredoc).

After editing, confirm with `grep`:

```bash
grep -n "cloudflare\|cp_dns_zones" tofu/layers/03-talos/variables.tf
```

Expected: no output (no remaining matches).

- [ ] **Step 5: Run `tofu validate` against 03-talos**

```bash
cd tofu/layers/03-talos
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

If validate fails citing `cloudflare_api_token` or `cp_dns_zones` references: search 03-talos for any leftover references and remove them too:

```bash
grep -rn "cloudflare_api_token\|cp_dns_zones\|module\.cluster_dns\|data\.cloudflare_dns_records" tofu/layers/03-talos/
```

Expected: only the new `removed.tf` matches `module.cluster_dns`.

- [ ] **Step 6: Validate 04-dns still passes (the moved code now compiles in its new home)**

```bash
cd tofu/layers/04-dns
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add tofu/layers/03-talos/removed.tf tofu/layers/03-talos/dns.tf tofu/layers/03-talos/versions.tf tofu/layers/03-talos/variables.tf
git commit -m "03-talos: remove DNS — module.cluster_dns leaves state via removed{destroy=false}"
```

---

## Task 7: Open PR + verify CI plan output

**Goal:** Push branch, open PR, confirm `tofu-plan` shows the expected diffs for both layers.

- [ ] **Step 1: Push branch**

```bash
git push -u origin dns-layer-split
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "split cluster DNS into 04-dns" --body "$(cat <<'EOF'
## Summary
Carves `prod.<zone>` LB round-robin out of `03-talos` into a new `04-dns` layer running in parallel with `04-flux`. A Cloudflare API failure no longer fails Talos config apply. Adding a non-LB node produces a no-op DNS plan.

Spec: `docs/superpowers/specs/2026-05-20-dns-layer-split-design.md`
Plan: `docs/superpowers/plans/2026-05-20-dns-layer-split-plan.md`

## Changes
- New layer `tofu/layers/04-dns/` (backend, versions, variables, main, dns).
- `tofu/modules/cloudflare-dns/main.tf` — add `create_before_destroy` to avoid NXDOMAIN on IP change.
- `tofu/layers/03-talos/removed.tf` — transitional `removed { destroy = false }` for `module.cluster_dns`.
- `tofu/layers/03-talos/dns.tf` deleted; `cloudflare` provider + `cloudflare_api_token` + `cp_dns_zones` removed from 03-talos.
- `tofu-plan.yml` / `tofu-apply.yml` — new `dns` job, parallel with `flux`.
- `tofu-layer.yml` — per-resource change annotation for 04-dns plans.

## Test plan
- [ ] CI green: `tofu-plan` succeeds for both `03-talos` and `04-dns`.
- [ ] `03-talos` plan shows: `Plan: 0 to add, 0 to change, 0 to destroy. (~5 to forget)` — the `~5 to forget` accounts for the `removed { destroy = false }` block dropping module.cluster_dns instances from state without provider calls.
- [ ] `04-dns` plan annotation shows `create=N import=N destroy=0` where N matches the existing prod.stawi.org record count.
- [ ] After merge: `tofu-apply` succeeds for `03-talos` AND `04-dns`. `dig prod.stawi.org A +short` returns the expected IPs unchanged.
- [ ] Follow-up commit deletes `tofu/layers/03-talos/removed.tf` (Task 8 of the plan).
EOF
)"
```

- [ ] **Step 3: Inspect the PR's `tofu-plan / 03-talos` job log**

Wait for CI to run, then:

```bash
gh pr checks
gh run view "$(gh run list --workflow=tofu-plan --branch dns-layer-split --limit 1 --json databaseId -q '.[0].databaseId')" --log | grep -A 3 "Plan: " | head -20
```

Expected: 03-talos plan shows `0 to add, 0 to change, 0 to destroy` with N entries `(to forget)`. No `cloudflare_dns_record` destroys. No provider API calls.

If the plan shows actual destroys to `cloudflare_dns_record`: the `removed { destroy = false }` block did not apply correctly. Check that `removed.tf` is committed and that `module.cluster_dns` still appears in the existing `03-talos.tfstate` (otherwise the removed block has nothing to drop).

- [ ] **Step 4: Inspect the `04-dns` job log for the annotation**

```bash
gh run view "$(gh run list --workflow=tofu-plan --branch dns-layer-split --limit 1 --json databaseId -q '.[0].databaseId')" --log | grep "04-dns plan:"
```

Expected: one notice line like `::notice::04-dns plan: create=N update=0 destroy=0 replace=0` with N matching the number of existing `prod.stawi.org` A/AAAA records.

If N is much larger than expected (e.g. tries to create records that already exist in CF without being imported): the import-block lookup is missing records. Run `tofu output _debug_dns_to_import` against the 04-dns plan locally and compare with `_debug_dns_existing_canonical_keys`.

- [ ] **Step 5: Merge the PR**

Once both plan outputs look correct and a reviewer has confirmed the destroy clause's whitelist scope (name `in ["prod"]` AND type `in ["A", "AAAA"]`):

```bash
gh pr merge --squash
```

- [ ] **Step 6: Trigger tofu-apply and watch**

```bash
gh workflow run tofu-apply
sleep 5
APPLY_RUN=$(gh run list --workflow=tofu-apply --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$APPLY_RUN" --exit-status
```

Expected: both `03-talos` and `04-dns` jobs succeed.

- [ ] **Step 7: Post-apply verification**

```bash
dig prod.stawi.org A +short
dig prod.stawi.org AAAA +short
```

Expected: same IP sets as before the PR (the migration was no-op for end users).

---

## Task 8: Follow-up commit — delete transitional `removed.tf`

**Goal:** Clean up the one-shot migration aid after it's done its job. Performed in a separate commit after Task 7's apply succeeds.

**Files:**
- Delete: `tofu/layers/03-talos/removed.tf`

- [ ] **Step 1: Confirm the `removed` block has been consumed**

Before deleting, confirm `module.cluster_dns` is no longer in 03-talos's tfstate:

```bash
aws s3 cp s3://cluster-tofu-state/production/03-talos.tfstate /tmp/03-talos.tfstate \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
jq '[.resources[] | select(.module // "" | startswith("module.cluster_dns"))] | length' /tmp/03-talos.tfstate
rm /tmp/03-talos.tfstate
```

Expected: `0`.

If non-zero: Task 7's apply didn't run successfully or the `removed` block didn't apply. Do not delete `removed.tf` yet — re-run `tofu-apply` for 03-talos and re-check.

- [ ] **Step 2: Delete the file**

```bash
git rm tofu/layers/03-talos/removed.tf
```

- [ ] **Step 3: Validate 03-talos still passes**

```bash
cd tofu/layers/03-talos
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit and open follow-up PR**

```bash
git checkout -b cleanup-03-talos-removed-block
git add tofu/layers/03-talos/removed.tf
git commit -m "03-talos: drop transitional removed.tf (cluster_dns long gone from state)"
git push -u origin cleanup-03-talos-removed-block
gh pr create --title "03-talos: drop transitional removed.tf" --body "Migration aid from PR #<TASK7_PR_NUMBER>. The removed { destroy = false } block dropped module.cluster_dns from state; no longer needed."
```

---

## Self-review checklist

After completing all tasks, verify:

- [ ] **Spec coverage:** every section of `docs/superpowers/specs/2026-05-20-dns-layer-split-design.md` maps to a task. Particularly:
  - Layer placement (Task 1, Task 5)
  - State / provider (Task 1)
  - Components: main, dns, variables, versions (Tasks 1, 3)
  - Removed from 03-talos (Task 6)
  - Workflow jobs (Task 5)
  - Lifecycle hardening (Task 2)
  - Robustness adds: pre-apply drift surfacing (Task 4), `create_before_destroy` (Task 2), per-record granularity (preserved in Task 3 via for_each keying), stale-record cleanup (deferred per spec)
  - Migration via `removed { destroy = false }` + import self-heal (Task 6)
- [ ] **No placeholders:** no "TBD", "TODO", "implement later" — every step has the actual code or command. (`<TASK7_PR_NUMBER>` in Task 8 is an operator-substituted reference, not a defect.)
- [ ] **Type consistency:** locals `all_nodes_from_state`, `cluster_dns_intended_records`, `existing_records_by_zone_canonical_key`, `zones_by_id`, `zones_by_id_to_zone_id` are referenced consistently across `main.tf` and `dns.tf`.
- [ ] **Tests:** every task ends with `tofu validate` (the closest tofu primitive to "unit test"); Task 7 adds a live plan-output check and a post-apply `dig`.
