# Omni-on-Contabo realignment — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move omni-host + sole CP back to Contabo (stable IPv4); consolidate OCI bwire compute to one Always-Free worker (4 OCPU / 24 GB / 180 GB); keep all OCI buckets/IAM in bwire intact; build a parallel `omni-host-contabo` module so substrate switches stay tfvar-driven.

**Architecture:** Two parallel `omni-host-*` modules under `tofu/modules/`, both exposing the same outputs. `00-omni-server/main.tf` picks via `var.omni_host_provider` (`"contabo" | "oci"`) using `count`-gated module instantiation and `coalescelist()`-derived locals. Templates that don't differ by substrate (`docker-compose`, `cert-bootstrap`, `omni-backup`) are extracted to `tofu/shared/templates/omni-host/` and consumed by both modules. `random_uuid.omni_account_id` and `random_password.dex_omni_client_secret` are hoisted out of the modules up to the layer so values stay stable across substrate switches.

**Tech Stack:** OpenTofu (Terraform-compatible), Contabo provider, OCI provider, Cloudflare provider, Talos / Omni / SideroLink, Ubuntu 24.04 LTS + Docker on the omni-host, R2 (S3-compat) for tofu state + inventory.

**Reference spec:** [`docs/superpowers/specs/2026-05-03-omni-contabo-realignment-design.md`](../specs/2026-05-03-omni-contabo-realignment-design.md)

---

## Pre-flight

This plan assumes:
- Working tree on a feature branch (e.g. `feat/omni-contabo-realignment`).
- Pre-commit hooks active: `tofu fmt`, `tofu validate`, `tflint`, `trivy` run on every commit. **Do not bypass with `--no-verify`.** If a hook fails, fix the issue and create a NEW commit (per repo policy).
- `tofu init` already run on `00-omni-server`, `01-contabo-infra`, `02-oracle-infra` (so `tofu validate` works locally).
- The cluster is in its current post-PR-156 state: omni-host on `oci-bwire-omni`, CP on `oci-bwire-node-1`, Contabo nodes (bwire-1/2/3) all Talos workers.

---

### Task 1: Branch + worktree setup

**Files:** none (git only)

- [ ] **Step 1: Create feature branch**

```bash
git checkout -b feat/omni-contabo-realignment
git push -u origin feat/omni-contabo-realignment
```

Expected: branch tracking origin, no commits ahead yet.

- [ ] **Step 2: Confirm clean tree**

```bash
git status --short
```

Expected: empty output.

---

### Task 2: Hoist `omni_account_id` + `dex_omni_client_secret` out of `omni-host-oci`

The `random_uuid` baked into every Machine's SideroLink config must NOT change when the substrate changes. Today both randoms live inside `omni-host-oci`; switching substrates would generate fresh ones and orphan every cluster the host has provisioned. Hoist them up to `00-omni-server` so a single random pair feeds whichever substrate is active.

This is a refactor — plan must show no changes after the state-mv step.

**Files:**
- Modify: `tofu/modules/omni-host-oci/main.tf` (delete the two `random_*` resources, add the two as input variables)
- Modify: `tofu/modules/omni-host-oci/variables.tf` (add the two variables)
- Create: `tofu/layers/00-omni-server/randoms.tf` (new home for the resources)
- Modify: `tofu/layers/00-omni-server/main.tf` (pass new vars into module)

- [ ] **Step 1: Add new variables to the module**

Append to `tofu/modules/omni-host-oci/variables.tf`:

```hcl
variable "omni_account_id" {
  description = "Omni account UUID, baked into every Machine's SideroLink config. Pinned (lifecycle ignore_changes upstream)."
  type        = string
}

variable "dex_omni_client_secret" {
  description = "Dex OAuth client secret for Omni. Pinned upstream."
  type        = string
  sensitive   = true
}
```

- [ ] **Step 2: Replace in-module randoms with variable references**

In `tofu/modules/omni-host-oci/main.tf`, **delete** these two blocks (lines ~12-23):

```hcl
resource "random_uuid" "omni_account_id" {
  lifecycle { ignore_changes = [keepers] }
}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
  lifecycle { ignore_changes = [length, special] }
}
```

Then in the same file, replace these template input lines:

```hcl
omni_account_id        = random_uuid.omni_account_id.result
...
dex_omni_client_secret = random_password.dex_omni_client_secret.result
```

with:

```hcl
omni_account_id        = var.omni_account_id
...
dex_omni_client_secret = var.dex_omni_client_secret
```

(There are two `dex_omni_client_secret` references — one in `local.docker_compose_yaml`, one in `local.user_data`. Both need updating.)

- [ ] **Step 3: Create the layer-level randoms file**

Create `tofu/layers/00-omni-server/randoms.tf`:

```hcl
# Pinned secrets that ride with the omni-host across substrate
# switches. Live at layer scope (not inside any omni-host-* module)
# so flipping var.omni_host_provider doesn't rotate them — that
# would orphan every cluster ever provisioned by this Omni instance.

resource "random_uuid" "omni_account_id" {
  lifecycle { ignore_changes = [keepers] }
}

resource "random_password" "dex_omni_client_secret" {
  length  = 64
  special = false
  lifecycle { ignore_changes = [length, special] }
}
```

- [ ] **Step 4: Pass the two new vars into the module call**

In `tofu/layers/00-omni-server/main.tf`, inside the `module "omni_host_oci"` block (currently around line 71), add these two lines (placement order doesn't matter; group with other top-level inputs):

```hcl
  omni_account_id        = random_uuid.omni_account_id.result
  dex_omni_client_secret = random_password.dex_omni_client_secret.result
```

- [ ] **Step 5: Move the existing random resources into layer state**

The state-mv preserves the existing values so `tofu plan` stays a no-op.

```bash
cd tofu/layers/00-omni-server
tofu init
tofu state mv 'module.omni_host_oci.random_uuid.omni_account_id' random_uuid.omni_account_id
tofu state mv 'module.omni_host_oci.random_password.dex_omni_client_secret' random_password.dex_omni_client_secret
```

Expected: each command prints `Successfully moved 1 object`.

- [ ] **Step 6: Verify plan is a no-op**

```bash
tofu plan -lock=false -no-color | grep -E '^(Plan:|No changes)'
```

Expected: `No changes. Your infrastructure matches the configuration.`

If plan shows changes, **stop** and reconcile — the refactor must be perfectly behaviour-preserving.

- [ ] **Step 7: Commit**

```bash
cd ../../..
git add tofu/modules/omni-host-oci/main.tf tofu/modules/omni-host-oci/variables.tf \
        tofu/layers/00-omni-server/randoms.tf tofu/layers/00-omni-server/main.tf
git commit -m "omni-host: hoist account_id + dex secret to 00-omni-server scope

Module-scoped randoms would rotate on substrate switch, orphaning
every cluster this Omni has provisioned. Pinning at layer scope keeps
values stable across the upcoming Contabo/OCI module pair.

State migration: tofu state mv from module.* to layer root."
```

---

### Task 3: Extract `docker-compose.yaml.tftpl` to shared templates

The Docker-compose stack (Omni + Dex + nginx) is fully substrate-agnostic — same containers, same env, same volumes whether the host is OCI or Contabo. Extract once, share twice.

`cert-bootstrap.sh` and `omni-backup.sh` are currently embedded inline in the OCI cloud-init via heredocs (not separate files), so leave them inlined for now — when the Contabo cloud-init copies the OCI cloud-init structure (Task 7), it'll inherit the same heredocs. A future task can extract them if duplication grows painful.

**Files:**
- Create: `tofu/shared/templates/omni-host/docker-compose.yaml.tftpl` (moved from module)
- Modify: `tofu/modules/omni-host-oci/main.tf` (templatefile path)
- Delete: `tofu/modules/omni-host-oci/docker-compose.yaml.tftpl`

- [ ] **Step 1: Move the file to the shared location**

```bash
mkdir -p tofu/shared/templates/omni-host
git mv tofu/modules/omni-host-oci/docker-compose.yaml.tftpl tofu/shared/templates/omni-host/docker-compose.yaml.tftpl
```

- [ ] **Step 2: Update the templatefile path in the module**

In `tofu/modules/omni-host-oci/main.tf`, change:

```hcl
  docker_compose_yaml = templatefile(
    "${path.module}/docker-compose.yaml.tftpl",
```

to:

```hcl
  docker_compose_yaml = templatefile(
    "${path.module}/../../shared/templates/omni-host/docker-compose.yaml.tftpl",
```

- [ ] **Step 3: Verify plan is a no-op**

```bash
cd tofu/layers/00-omni-server
tofu plan -lock=false -no-color | grep -E '^(Plan:|No changes)'
```

Expected: `No changes.` (the rendered docker-compose YAML is byte-identical).

- [ ] **Step 4: Commit**

```bash
cd ../../..
git add tofu/shared/templates/omni-host/docker-compose.yaml.tftpl tofu/modules/omni-host-oci/main.tf
git commit -m "omni-host-oci: extract docker-compose.yaml.tftpl to shared templates

Stack definition is substrate-agnostic. Hoisting it to
tofu/shared/templates/omni-host/ lets the upcoming omni-host-contabo
module consume the same template without copy-paste drift."
```

---

### Task 4: Create `omni-host-contabo` module skeleton (versions + variables + outputs)

Define the module's interface BEFORE its body. The interface mirrors `omni-host-oci`'s outputs exactly so 00-omni-server can swap providers without touching downstream consumers.

**Files:**
- Create: `tofu/modules/omni-host-contabo/versions.tf`
- Create: `tofu/modules/omni-host-contabo/variables.tf`
- Create: `tofu/modules/omni-host-contabo/outputs.tf`

- [ ] **Step 1: versions.tf**

Create `tofu/modules/omni-host-contabo/versions.tf`:

```hcl
terraform {
  required_providers {
    contabo    = { source = "contabo/contabo" }
    cloudflare = { source = "cloudflare/cloudflare" }
    random     = { source = "hashicorp/random" }
  }
}
```

- [ ] **Step 2: variables.tf**

Create `tofu/modules/omni-host-contabo/variables.tf`. Inputs match `omni-host-oci`'s contract minus OCI-specific knobs (`compartment_ocid`, `availability_domain_index`, `ubuntu_image_ocid`, `vcn_id`, `subnet_id`, `enable_ipv6`, `shape`, `ocpus`, `memory_gb`, `boot_volume_size_gb`), plus Contabo-specific knobs (`vps_id`, `region`, `image_id`, `force_reinstall_generation`, the four Contabo API credentials):

```hcl
# Substrate-specific.
variable "vps_id" {
  description = "Contabo VPS instance ID adopted by this module (the existing VPS that becomes the omni-host)."
  type        = string
}

variable "name" {
  description = "Hostname / display_name for the omni-host VPS."
  type        = string
}

variable "region" {
  description = "Contabo region (e.g. EU)."
  type        = string
}

variable "image_id" {
  description = "Contabo Ubuntu LTS image UUID. Provided by the contabo-image-lookup module at the layer level."
  type        = string
}

variable "force_reinstall_generation" {
  description = "Bump to force a full reinstall via Contabo API. Mirrors node-contabo's mechanism."
  type        = number
  default     = 1
}

variable "contabo_client_id" {
  type      = string
  sensitive = true
}
variable "contabo_client_secret" {
  type      = string
  sensitive = true
}
variable "contabo_api_user" {
  type      = string
  sensitive = true
}
variable "contabo_api_password" {
  type      = string
  sensitive = true
}

# Substrate-agnostic (same shape as omni-host-oci's variables).
variable "omni_version" { type = string }
variable "dex_version" { type = string }
variable "nginx_version" { type = string }
variable "omni_account_id" { type = string }
variable "dex_omni_client_secret" {
  type      = string
  sensitive = true
}
variable "omni_account_name" { type = string }
variable "siderolink_api_advertised_host" { type = string }
variable "siderolink_wireguard_advertised_host" { type = string }
variable "github_oidc_client_id" {
  type      = string
  sensitive = true
}
variable "github_oidc_client_secret" {
  type      = string
  sensitive = true
}
variable "github_oidc_allowed_orgs" {
  type    = list(string)
  default = []
}
variable "cf_dns_api_token" {
  type      = string
  sensitive = true
}
variable "initial_users" {
  type    = list(string)
  default = []
}
variable "eula_name" { type = string }
variable "eula_email" { type = string }
variable "etcd_backup_enabled" {
  type    = bool
  default = false
}
variable "ssh_authorized_keys" {
  type    = list(string)
  default = []
}
variable "vpn_users" {
  type = map(object({
    public_key = string
  }))
  default = {}
}

# R2 — used by on-host omni-backup tarball script (separate from
# Omni's etcd-backup-s3 which writes to OCI per cluster-level config).
variable "r2_account_id" { type = string }
variable "r2_access_key_id" {
  type      = string
  sensitive = true
}
variable "r2_secret_access_key" {
  type      = string
  sensitive = true
}
variable "r2_bucket_name" {
  type    = string
  default = "omni-state-backup"
}
variable "r2_backup_prefix" {
  type    = string
  default = ""
}
```

- [ ] **Step 3: outputs.tf**

Create `tofu/modules/omni-host-contabo/outputs.tf`. Output names + types must match `omni-host-oci`'s exactly so the conditional-modules pattern in 00-omni-server works.

First, check the OCI module's outputs:

```bash
cat tofu/modules/omni-host-oci/outputs.tf
```

Then create `tofu/modules/omni-host-contabo/outputs.tf` mirroring those names. Expected outputs (verify by reading the OCI file): `instance_id`, `ipv4`, `ipv6`. Sample:

```hcl
output "instance_id" {
  description = "Contabo VPS instance ID hosting Omni."
  value       = contabo_instance.this.id
}

output "ipv4" {
  description = "Public IPv4 of the omni-host."
  value       = contabo_instance.this.ip_config[0].v4[0].ip
}

output "ipv6" {
  description = "Public IPv6 of the omni-host (null if v6 not assigned by Contabo)."
  value       = try(contabo_instance.this.ip_config[0].v6[0].ip, null)
}
```

(Adjust output names to match the OCI module — if the OCI module's output is named differently, mirror it exactly.)

- [ ] **Step 4: Validate**

```bash
cd tofu/modules/omni-host-contabo
tofu init -backend=false
tofu validate
```

Expected: `Success! The configuration is valid.`

(Validation will fail until `main.tf` exists with the referenced resources — Task 5 closes this. For now, accept "Reference to undeclared resource" only on `contabo_instance.this`. If you want a green validate now, add a placeholder `resource "null_resource" "placeholder" {}` and an output value of `null`; remove in Task 5.)

- [ ] **Step 5: Commit**

```bash
cd ../../..
git add tofu/modules/omni-host-contabo/
git commit -m "omni-host-contabo: module skeleton (versions + variables + outputs)"
```

---

### Task 5: `omni-host-contabo/main.tf` — VPS adoption + reinstall + cloud-init wiring

The module body. Pattern mirrors `node-contabo`'s `contabo_instance` + `null_resource.ensure_image` + `ensure-image.sh`, plus the omni-host-specific cloud-init + waiter from `omni-host-oci`.

**Files:**
- Create: `tofu/modules/omni-host-contabo/main.tf`
- Create: `tofu/modules/omni-host-contabo/ensure-image.sh` (copied from `node-contabo`)

- [ ] **Step 1: Copy `ensure-image.sh` from node-contabo**

```bash
cp tofu/modules/node-contabo/ensure-image.sh tofu/modules/omni-host-contabo/ensure-image.sh
chmod +x tofu/modules/omni-host-contabo/ensure-image.sh
```

(The script is generic — instance ID + target image ID, no node-vs-omni-host coupling.)

- [ ] **Step 2: main.tf**

Create `tofu/modules/omni-host-contabo/main.tf`:

```hcl
# tofu/modules/omni-host-contabo/main.tf
#
# Single Contabo VPS (existing, adopted by id) running Omni + Dex +
# nginx via docker-compose. Configuration declarative via cloud-init.
# Contabo substrate variant of tofu/modules/omni-host-oci.
#
# Two-phase lifecycle (mirrors node-contabo):
#   - contabo_instance.this owns naming + image_id + product/region.
#     image_id changes are ignored at provider level (the provider's
#     reinstall path is broken — see node-contabo comment).
#   - null_resource.ensure_image owns the actual reinstall trigger via
#     ensure-image.sh, which PUTs a full payload to Contabo's API.
#     Bumping force_reinstall_generation re-runs unconditionally.

locals {
  docker_compose_yaml = templatefile(
    "${path.module}/../../shared/templates/omni-host/docker-compose.yaml.tftpl",
    {
      omni_version                         = var.omni_version
      dex_version                          = var.dex_version
      nginx_version                        = var.nginx_version
      omni_account_id                      = var.omni_account_id
      omni_account_name                    = var.omni_account_name
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      dex_omni_client_secret               = var.dex_omni_client_secret
      initial_users                        = var.initial_users
      eula_name                            = var.eula_name
      eula_email                           = var.eula_email
      etcd_backup_enabled                  = var.etcd_backup_enabled
    }
  )

  user_data = templatefile(
    "${path.module}/cloud-init.yaml.tftpl",
    {
      name                                 = var.name
      docker_compose_yaml                  = local.docker_compose_yaml
      dex_omni_client_secret               = var.dex_omni_client_secret
      siderolink_api_advertised_host       = var.siderolink_api_advertised_host
      siderolink_wireguard_advertised_host = var.siderolink_wireguard_advertised_host
      github_oidc_client_id                = var.github_oidc_client_id
      github_oidc_client_secret            = var.github_oidc_client_secret
      github_oidc_allowed_orgs             = var.github_oidc_allowed_orgs
      cf_dns_api_token                     = var.cf_dns_api_token
      eula_email                           = var.eula_email
      ssh_authorized_keys                  = var.ssh_authorized_keys
      r2_account_id                        = var.r2_account_id
      r2_access_key_id                     = var.r2_access_key_id
      r2_secret_access_key                 = var.r2_secret_access_key
      r2_bucket_name                       = var.r2_bucket_name
      r2_backup_prefix                     = var.r2_backup_prefix
      vpn_users = {
        for idx, name in sort(keys(var.vpn_users)) :
        name => {
          public_key  = var.vpn_users[name].public_key
          assigned_ip = "10.100.0.${idx + 2}"
        }
      }
    }
  )
}

resource "contabo_instance" "this" {
  display_name = var.name
  region       = var.region
  image_id     = var.image_id
  period       = 1
  user_data    = local.user_data

  # See node-contabo's identical block: the provider's image_id-only
  # PUT is broken, so we ignore it and let ensure-image.sh own
  # reinstall drift correction.
  lifecycle {
    ignore_changes = [image_id]
  }
}

resource "null_resource" "ensure_image" {
  triggers = {
    instance_id                = contabo_instance.this.id
    target_image_id            = var.image_id
    force_reinstall_generation = var.force_reinstall_generation
    user_data_sha256           = sha256(local.user_data)
  }

  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      INSTANCE_ID           = contabo_instance.this.id
      TARGET_IMAGE_ID       = var.image_id
      USER_DATA             = local.user_data
      CONTABO_CLIENT_ID     = var.contabo_client_id
      CONTABO_CLIENT_SECRET = var.contabo_client_secret
      CONTABO_API_USER      = var.contabo_api_user
      CONTABO_API_PASSWORD  = var.contabo_api_password
      NODE_ROLE             = "omni-host"
      FORCE_REINSTALL       = var.force_reinstall_generation > 1 ? "1" : "0"
    }
    command = "${path.module}/ensure-image.sh"
  }
}

# Block downstream layers on omni-stack readiness, same as omni-host-oci.
resource "null_resource" "wait_for_omni_ready" {
  depends_on = [null_resource.ensure_image]

  triggers = {
    instance_id = contabo_instance.this.id
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      ENDPOINT = "https://${var.siderolink_api_advertised_host}/healthz"
    }
    command = <<-EOT
      set -euo pipefail
      echo "[wait_for_omni_ready] polling $ENDPOINT"
      deadline=$(( $(date +%s) + 600 ))
      while :; do
        code=$(curl -ksS -o /dev/null -w '%%{http_code}' --max-time 5 "$ENDPOINT" 2>/dev/null || echo 000)
        if [[ "$code" == "200" ]]; then
          echo "[wait_for_omni_ready] $ENDPOINT returned 200"
          exit 0
        fi
        if [[ $(date +%s) -ge $deadline ]]; then
          echo "[wait_for_omni_ready] timed out after 10min waiting for $ENDPOINT (last code: $code)" >&2
          exit 1
        fi
        sleep 10
      done
    EOT
  }
}
```

**Open question to resolve while writing**: the `node-contabo` module sets `user_data` on the `contabo_instance` resource? Verify via `grep -n user_data tofu/modules/node-contabo/main.tf` — if node-contabo does NOT set `user_data` on the resource (because Talos boots into maintenance with no cloud-init), but the `contabo_instance` resource type does support a `user_data` argument that the provider passes to Contabo's API, this module needs to set it. If Contabo discards `user_data` set on resource and only honors it in the API PUT-payload, then `ensure-image.sh` must include `user_data` in its payload (the env var `USER_DATA` is passed for this — verify the script reads it).

If `ensure-image.sh` doesn't currently consume `USER_DATA`, this is a bug we need to fix in Task 5b. Plan adjustment:

- [ ] **Step 3: Verify `ensure-image.sh` user_data wiring**

```bash
grep -n -E 'user_data|USER_DATA' tofu/modules/omni-host-contabo/ensure-image.sh
```

If matches show `USER_DATA` being assembled into the API PUT-payload: good, no change needed.

If no matches: `ensure-image.sh` ignores user_data. Patch it to include user_data in the payload — Contabo's `/compute/instances/<id>/actions/reinstall` API takes `imageId`, `userData` (base64), and `applicationId`. Add to the script:

```bash
# In the section that builds the JSON payload (look for jq or printf '{ ... }'):
# add to the JSON body:
#   "userData": "$(printf '%s' "$USER_DATA" | base64 -w0)"
```

Defer the exact patch to the implementing agent based on the script's structure. Verify via local dry-run that the script accepts `USER_DATA=""` (no user_data) gracefully too, since `node-contabo` callers won't set it.

- [ ] **Step 4: Validate**

```bash
cd tofu/modules/omni-host-contabo
tofu init -backend=false
tofu validate
```

Expected: `Success! The configuration is valid.` (assumes Task 6's cloud-init exists; if not, you'll see "no such file" — proceed to Task 6 then re-validate.)

- [ ] **Step 5: Commit**

```bash
cd ../../..
git add tofu/modules/omni-host-contabo/main.tf tofu/modules/omni-host-contabo/ensure-image.sh
git commit -m "omni-host-contabo: VPS adoption + ensure-image + cloud-init wiring

Mirrors node-contabo's two-phase lifecycle: contabo_instance owns
naming/image_id with image_id ignore_changes; null_resource.ensure_image
owns the actual reinstall via ensure-image.sh. wait_for_omni_ready
copied from omni-host-oci (identical poll loop on /healthz)."
```

---

### Task 6: `omni-host-contabo/cloud-init.yaml.tftpl`

Per-substrate cloud-init: same Docker stack as OCI but adds host nftables rules (Contabo has no security-list equivalent). Start by copying the OCI file verbatim, then layer the nftables stanza.

**Files:**
- Create: `tofu/modules/omni-host-contabo/cloud-init.yaml.tftpl`

- [ ] **Step 1: Read the OCI cloud-init template end-to-end**

```bash
wc -l tofu/modules/omni-host-oci/cloud-init.yaml.tftpl
cat tofu/modules/omni-host-oci/cloud-init.yaml.tftpl
```

Note especially: `apt:` Docker source line uses `arch=arm64`. Contabo VPSes are x86_64 (Intel), so this MUST flip to `arch=amd64`.

- [ ] **Step 2: Copy the OCI template as the starting point**

```bash
cp tofu/modules/omni-host-oci/cloud-init.yaml.tftpl tofu/modules/omni-host-contabo/cloud-init.yaml.tftpl
```

- [ ] **Step 3: Flip Docker source arch from arm64 to amd64**

In `tofu/modules/omni-host-contabo/cloud-init.yaml.tftpl`, change:

```yaml
      source: "deb [arch=arm64 signed-by=$KEY_FILE] https://download.docker.com/linux/ubuntu noble stable"
```

to:

```yaml
      source: "deb [arch=amd64 signed-by=$KEY_FILE] https://download.docker.com/linux/ubuntu noble stable"
```

- [ ] **Step 4: Add nftables ruleset**

The OCI template already has `nftables` in its package list (because it might be used selectively), but doesn't enable or configure rules. Contabo needs both: enabled + ruleset.

Append a new entry to the `write_files:` block (place near the end of `write_files:` so the order doesn't disrupt anything else):

```yaml
  - path: /etc/nftables.conf
    permissions: '0644'
    owner: root:root
    content: |
      #!/usr/sbin/nft -f
      flush ruleset

      table inet filter {
        chain input {
          type filter hook input priority filter; policy drop;

          # Connection tracking + loopback.
          ct state established,related accept
          ct state invalid drop
          iif lo accept

          # ICMPv4 + ICMPv6 (router discovery, neighbour discovery,
          # ping). Without these, IPv6 connectivity falls apart.
          ip protocol icmp accept
          ip6 nexthdr icmpv6 accept

          # SSH — gated by ssh_authorized_keys variable. If the operator
          # provided keys, allow public 22; if not, the OCI substrate
          # disables SSH entirely. Mirror that here: do NOT open 22 by
          # default. Operator opens via WireGuard (see below) and only
          # needs public 22 during initial bootstrap (template renders
          # this rule conditionally).
%{ if length(ssh_authorized_keys) > 0 ~}
          tcp dport 22 accept
%{ endif ~}

          # Omni: HTTP (LE renewal redirect), HTTPS (UI), SideroLink
          # API, k8s-proxy, SideroLink WG (UDP), admin WG (UDP).
          tcp dport { 80, 443, 8090, 8100 } accept
          udp dport { 50180, 51820 } accept
        }

        chain forward { type filter hook forward priority filter; policy drop; }
        chain output { type filter hook output priority filter; policy accept; }
      }

  - path: /etc/systemd/system/nftables.service.d/override.conf
    permissions: '0644'
    owner: root:root
    content: |
      [Unit]
      # Bring the firewall up before Docker so containers don't briefly
      # bind to ports that are still wide-open at the host edge.
      Before=docker.service
```

- [ ] **Step 5: Enable nftables service**

In the `runcmd:` block, add **before** any `docker compose up` line:

```yaml
  - [systemctl, enable, --now, nftables.service]
```

- [ ] **Step 6: Validate the template renders**

A quick syntax check — write a one-shot test in a scratch dir:

```bash
mkdir -p /tmp/scratch-tftpl-check
cat > /tmp/scratch-tftpl-check/main.tf <<'EOF'
variable "ssh_authorized_keys" { type = list(string) }
variable "vpn_users" { type = any }
output "out" {
  value = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    name = "test"
    docker_compose_yaml = "version: '3'"
    dex_omni_client_secret = "x"
    siderolink_api_advertised_host = "cp.test"
    siderolink_wireguard_advertised_host = "cpd.test"
    github_oidc_client_id = "x"
    github_oidc_client_secret = "x"
    github_oidc_allowed_orgs = []
    cf_dns_api_token = "x"
    eula_email = "x@x"
    ssh_authorized_keys = var.ssh_authorized_keys
    r2_account_id = "x"
    r2_access_key_id = "x"
    r2_secret_access_key = "x"
    r2_bucket_name = "x"
    r2_backup_prefix = ""
    vpn_users = var.vpn_users
  })
}
EOF
cp tofu/modules/omni-host-contabo/cloud-init.yaml.tftpl /tmp/scratch-tftpl-check/
cd /tmp/scratch-tftpl-check
tofu init -backend=false
echo 'ssh_authorized_keys = []' > terraform.tfvars
echo 'vpn_users = {}' >> terraform.tfvars
tofu plan -no-color 2>&1 | tail -20
cd - && rm -rf /tmp/scratch-tftpl-check
```

Expected: plan succeeds, no `Error: Failed to read file` or `template error`.

- [ ] **Step 7: Module-level validate**

```bash
cd tofu/modules/omni-host-contabo
tofu validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 8: Commit**

```bash
cd ../../..
git add tofu/modules/omni-host-contabo/cloud-init.yaml.tftpl
git commit -m "omni-host-contabo: cloud-init with host nftables (no security-list on Contabo)

Cloned from omni-host-oci's cloud-init, switched Docker source arch
to amd64 (Contabo is Intel), and added an nftables ruleset that
matches what the OCI security list provides on the OCI substrate.
Public SSH gated by ssh_authorized_keys length (mirrors OCI module's
zero-key-disables-ssh behaviour)."
```

---

### Task 7: 00-omni-server — add Contabo provider, image lookup, conditional modules, locals, DNS reference flip

Wire `var.omni_host_provider` and the new module call into the layer. The variable defaults to `"oci"` so plan stays a no-op until the tfvars switch in Task 11.

**Files:**
- Modify: `tofu/layers/00-omni-server/variables.tf` (new vars)
- Modify: `tofu/layers/00-omni-server/main.tf` (provider, image lookup, conditional module, locals, DNS ref flip)
- Modify: `tofu/layers/00-omni-server/versions.tf` (add contabo provider)

- [ ] **Step 1: Add Contabo provider to versions.tf**

In `tofu/layers/00-omni-server/versions.tf`, add `contabo` to `required_providers` (mirror the entry from `01-contabo-infra/versions.tf` for the version pin):

```bash
grep -A2 'contabo' tofu/layers/01-contabo-infra/versions.tf
```

Apply the same `contabo = { source = "contabo/contabo", version = "..." }` block to `00-omni-server/versions.tf`.

- [ ] **Step 2: Add new variables**

Append to `tofu/layers/00-omni-server/variables.tf`:

```hcl
variable "omni_host_provider" {
  description = "Substrate hosting omni-host. 'contabo' (default) uses an existing Contabo VPS; 'oci' uses an OCI A1.Flex VM in bwire."
  type        = string
  default     = "oci"
  validation {
    condition     = contains(["contabo", "oci"], var.omni_host_provider)
    error_message = "omni_host_provider must be 'contabo' or 'oci'."
  }
}

variable "omni_host_contabo_vps_id" {
  description = "Contabo VPS ID adopted as the omni-host when omni_host_provider=='contabo'."
  type        = string
  default     = "202727781"
}

variable "omni_host_contabo_region" {
  description = "Contabo region for the omni-host VPS."
  type        = string
  default     = "EU"
}

variable "contabo_client_id" {
  type      = string
  sensitive = true
}
variable "contabo_client_secret" {
  type      = string
  sensitive = true
}
variable "contabo_api_user" {
  type      = string
  sensitive = true
}
variable "contabo_api_password" {
  type      = string
  sensitive = true
}

variable "force_reinstall_generation" {
  description = "Bump to force omni-host reinstall (Contabo substrate only)."
  type        = number
  default     = 1
}
```

- [ ] **Step 3: Add Contabo provider config to main.tf**

In `tofu/layers/00-omni-server/main.tf`, add (near the existing `provider "oci"`):

```hcl
provider "contabo" {
  oauth2_client_id     = var.contabo_client_id
  oauth2_client_secret = var.contabo_client_secret
  oauth2_user         = var.contabo_api_user
  oauth2_pass         = var.contabo_api_password
}
```

(Verify the exact provider attribute names against `tofu/layers/01-contabo-infra/main.tf`'s provider block — Contabo's provider may use slightly different keys.)

- [ ] **Step 4: Add Contabo image lookup module**

In `tofu/layers/00-omni-server/main.tf`, after the contabo provider block, add:

```hcl
# Latest Ubuntu 24.04 LTS image_id for Contabo's standard VPS pool.
module "ubuntu_24_04_image_contabo" {
  count  = var.omni_host_provider == "contabo" ? 1 : 0
  source = "../../modules/contabo-image-lookup"

  name                  = "Ubuntu 24.04"
  contabo_client_id     = var.contabo_client_id
  contabo_client_secret = var.contabo_client_secret
  contabo_api_user      = var.contabo_api_user
  contabo_api_password  = var.contabo_api_password
}
```

(Confirm input names against `tofu/modules/contabo-image-lookup/variables.tf` — adjust if the module's variables differ.)

- [ ] **Step 5: Wrap existing `module "omni_host_oci"` in `count` and add new `module "omni_host_contabo"`**

In `tofu/layers/00-omni-server/main.tf`, modify the existing module call:

```hcl
module "omni_host_oci" {
  count     = var.omni_host_provider == "oci" ? 1 : 0
  source    = "../../modules/omni-host-oci"
  providers = { oci = oci.bwire }
  # ... existing inputs unchanged ...
}
```

Then add the new module call right after:

```hcl
module "omni_host_contabo" {
  count  = var.omni_host_provider == "contabo" ? 1 : 0
  source = "../../modules/omni-host-contabo"

  vps_id                     = var.omni_host_contabo_vps_id
  name                       = "contabo-bwire-node-3"
  region                     = var.omni_host_contabo_region
  image_id                   = try(module.ubuntu_24_04_image_contabo[0].id, "")
  force_reinstall_generation = var.force_reinstall_generation
  contabo_client_id          = var.contabo_client_id
  contabo_client_secret      = var.contabo_client_secret
  contabo_api_user           = var.contabo_api_user
  contabo_api_password       = var.contabo_api_password

  omni_version                         = var.omni_version
  dex_version                          = var.dex_version
  nginx_version                        = var.nginx_version
  omni_account_id                      = random_uuid.omni_account_id.result
  dex_omni_client_secret               = random_password.dex_omni_client_secret.result
  omni_account_name                    = "stawi"
  siderolink_api_advertised_host       = "cp.stawi.org"
  siderolink_wireguard_advertised_host = "cpd.stawi.org"
  github_oidc_client_id                = var.github_oidc_client_id
  github_oidc_client_secret            = var.github_oidc_client_secret
  cf_dns_api_token                     = var.cloudflare_api_token
  initial_users                        = [for e in split(",", var.omni_initial_users) : trimspace(e) if trimspace(e) != ""]
  eula_name                            = var.omni_eula_name
  eula_email                           = var.omni_eula_email
  etcd_backup_enabled                  = var.etcd_backup_enabled
  vpn_users                            = var.vpn_users
  ssh_authorized_keys                  = []  # public SSH off post-bootstrap; admin via WG

  r2_account_id        = var.r2_account_id
  r2_access_key_id     = var.r2_access_key_id
  r2_secret_access_key = var.r2_secret_access_key
}
```

- [ ] **Step 6: Add omni-host locals**

Add to `tofu/layers/00-omni-server/main.tf` (place near the existing `locals` block around line 126):

```hcl
locals {
  # Active omni-host outputs, substrate-agnostic. Exactly one of the
  # two modules has count=1; coalescelist picks its outputs.
  omni_host_ipv4 = coalescelist(
    module.omni_host_contabo[*].ipv4,
    module.omni_host_oci[*].ipv4,
  )[0]
  omni_host_ipv6 = coalescelist(
    module.omni_host_contabo[*].ipv6,
    module.omni_host_oci[*].ipv6,
  )[0]
}
```

- [ ] **Step 7: Flip DNS resources to use the locals**

In `tofu/layers/00-omni-server/main.tf`, replace **all four** occurrences of `module.omni_host_oci.ipv4` with `local.omni_host_ipv4`, and `module.omni_host_oci.ipv6` with `local.omni_host_ipv6`:

```bash
grep -n 'module\.omni_host_oci\.ipv' tofu/layers/00-omni-server/main.tf
```

Expected before edit: 4 matches (cp_stawi, cp_stawi_v6, cpd_stawi, cpd_stawi_v6).

After edit, re-run the same grep — expected: 0 matches.

Also update `tofu/layers/00-omni-server/outputs.tf`'s `omni_host_instance_id`:

```hcl
output "omni_host_instance_id" {
  value = coalescelist(
    module.omni_host_contabo[*].instance_id,
    module.omni_host_oci[*].instance_id,
  )[0]
}
```

- [ ] **Step 8: Verify plan is a no-op (default provider still oci)**

```bash
cd tofu/layers/00-omni-server
tofu init -upgrade
tofu plan -lock=false -no-color | grep -E '^(Plan:|No changes)'
```

Expected: `No changes.` (because `var.omni_host_provider` defaults to `"oci"` and the Contabo module has count=0 so it doesn't materialize anything.)

If plan shows changes: most likely the OCI module instance address changed from `module.omni_host_oci` to `module.omni_host_oci[0]` due to `count` introduction. Fix with a `moved` block:

```hcl
moved {
  from = module.omni_host_oci
  to   = module.omni_host_oci[0]
}
```

Place this in `tofu/layers/00-omni-server/main.tf`. Re-run plan; expected `No changes.`

- [ ] **Step 9: Commit**

```bash
cd ../../..
git add tofu/layers/00-omni-server/main.tf tofu/layers/00-omni-server/variables.tf \
        tofu/layers/00-omni-server/versions.tf tofu/layers/00-omni-server/outputs.tf
git commit -m "00-omni-server: parallel omni-host modules behind var.omni_host_provider

Adds Contabo provider config, image lookup, count-gated module pair,
substrate-agnostic locals, and a moved{} block to keep the existing
oci module address stable. Default omni_host_provider='oci' keeps
plan clean; Task 11 flips to contabo via tfvars."
```

---

### Task 8: Reshape OCI bwire compute (R2 inventory mutation)

`oci-bwire-node-1` shrinks from 2/12/90 (CP) to 4/24/180 (worker), and `oci-bwire-omni` is no longer needed (omni moves off OCI). Both compute changes are driven by the per-account R2 inventory file `production/inventory/oracle/bwire/nodes.yaml`. There's no tofu source-tree change for this task; the operator runs the mutation tool.

The cluster inventory currently includes only `oci-bwire-node-1` (the omni-host VM is created by 00-omni-server, not 02-oracle-infra). So this task is a single inventory edit.

**Files:** R2 inventory (out-of-tree)

- [ ] **Step 1: Stage the R2 inventory change via `patch-inventory-node` workflow**

Trigger the patch-inventory-node workflow (added in commit `f6025ba`). Verify the workflow's input shape:

```bash
cat .github/workflows/patch-inventory-node.yml | head -60
```

Run the workflow (via `gh workflow run`) for `oracle/bwire/oci-bwire-node-1` with these patches:
- `role: worker` (verify it's already `worker`; no-op if so)
- `lb: true`
- `ocpus: 4`
- `memory_gb: 24`
- `boot_volume_size_gb: 180`

Example invocation (adjust input names to match the workflow's `inputs:` schema):

```bash
gh workflow run patch-inventory-node.yml \
  -f provider=oracle \
  -f account=bwire \
  -f node=oci-bwire-node-1 \
  -f patch='{"role":"worker","lb":true,"ocpus":4,"memory_gb":24,"boot_volume_size_gb":180}'
```

- [ ] **Step 2: Verify the inventory updated**

```bash
gh run list --workflow=patch-inventory-node.yml --limit=1
gh run view --log $(gh run list --workflow=patch-inventory-node.yml --limit=1 --json databaseId -q '.[0].databaseId')
```

Expected: workflow succeeded; the SOPS-encrypted YAML in R2 now reflects the new shape.

- [ ] **Step 3: No commit — inventory lives in R2, not git**

Note in the PR description that this inventory mutation has been pre-staged.

---

### Task 9: Drop bwire-3 from `01-contabo-infra` cluster pool

`contabo-bwire-node-3` (VPS 202727781) leaves the cluster — it becomes the omni-host substrate, owned by `00-omni-server`. Two changes:

1. Remove from the bootstrap fallback file (so `seed-inventory.sh` doesn't re-add it).
2. Remove from R2 inventory `production/inventory/contabo/bwire/nodes.yaml`.

**Files:**
- Modify: `tofu/shared/bootstrap/contabo-instance-ids.yaml`

- [ ] **Step 1: Edit the bootstrap fallback**

In `tofu/shared/bootstrap/contabo-instance-ids.yaml`, remove only the bwire-3 entry:

```yaml
contabo:
  bwire:
    contabo-bwire-node-1:
      contabo_instance_id: "202727783"
    contabo-bwire-node-2:
      contabo_instance_id: "202727782"
    # contabo-bwire-node-3 removed: VPS 202727781 is now the omni-host
    # (see tofu/layers/00-omni-server's omni-host-contabo module).
```

(Keep the comment explaining why so future readers know where the VPS went.)

- [ ] **Step 2: Patch R2 contabo bwire inventory — remove bwire-3, flip bwire-2 role to controlplane**

Run two patch-inventory-node invocations (the workflow handles both delete and edit; check its input schema):

```bash
# Remove bwire-3 entirely
gh workflow run patch-inventory-node.yml \
  -f provider=contabo -f account=bwire -f node=contabo-bwire-node-3 -f delete=true

# Flip bwire-2 to controlplane
gh workflow run patch-inventory-node.yml \
  -f provider=contabo -f account=bwire -f node=contabo-bwire-node-2 \
  -f patch='{"role":"controlplane","lb":false}'

# Confirm bwire-1 stays worker, lb false
gh workflow run patch-inventory-node.yml \
  -f provider=contabo -f account=bwire -f node=contabo-bwire-node-1 \
  -f patch='{"role":"worker","lb":false}'
```

If `patch-inventory-node` doesn't support deletion: edit `production/inventory/contabo/bwire/nodes.yaml` directly via `sops` and remove the `contabo-bwire-node-3:` map entry.

- [ ] **Step 3: Commit the bootstrap edit**

```bash
git add tofu/shared/bootstrap/contabo-instance-ids.yaml
git commit -m "contabo bootstrap: remove bwire-3 (becomes omni-host substrate)

VPS 202727781 leaves the cluster pool and is adopted by
00-omni-server's omni-host-contabo module instead. R2 inventory
mutated separately via patch-inventory-node."
```

---

### Task 10: Cluster spec — `Workers.size` 5 → 4

Post-realignment cluster shape: 1 CP (`contabo-bwire-node-2`) + 4 workers (`contabo-bwire-node-1`, `oci-bwire-node-1`, `oci-alimbacho67-node-1`, `oci-brianelvis33-node-1`). Workers MachineSet shrinks by one because `contabo-bwire-node-3` left the pool (now omni-host).

**Files:**
- Modify: `tofu/shared/clusters/main.yaml` (line ~203)

- [ ] **Step 1: Edit Workers.size**

In `tofu/shared/clusters/main.yaml`, change the Workers entry:

```yaml
  size: 5
```

to:

```yaml
  size: 4
```

(Verify exact location with `grep -n 'size:' tofu/shared/clusters/main.yaml` — line ~203 per Task-2 inspection.)

- [ ] **Step 2: Commit**

```bash
git add tofu/shared/clusters/main.yaml
git commit -m "clusters: Workers.size 5→4 (post-realignment)

bwire-3 leaves the cluster pool to host omni; net cluster shape is
1 CP + 4 workers (1 Contabo worker + 3 OCI workers)."
```

---

### Task 11: Flip the switch — `terraform.tfvars: omni_host_provider = "contabo"`

This is the apply trigger. After this commit lands and 00-omni-server applies, OCI omni-host destroys + Contabo omni-host creates within the same plan.

**Files:**
- Modify: `tofu/layers/00-omni-server/terraform.tfvars`

- [ ] **Step 1: Set the provider**

Append to `tofu/layers/00-omni-server/terraform.tfvars` (or update if the var is already present somehow):

```hcl
omni_host_provider = "contabo"
```

- [ ] **Step 2: Verify plan now shows the substrate switch**

```bash
cd tofu/layers/00-omni-server
tofu plan -lock=false -no-color > /tmp/contabo-switch-plan.txt
grep -E '^(Plan:|module\.)' /tmp/contabo-switch-plan.txt | head -50
```

Expected:
- `module.omni_host_oci[0].oci_core_instance.this` will be **destroyed**
- `module.omni_host_oci[0].*` resources destroyed
- `module.omni_host_contabo[0].contabo_instance.this` will be **created**
- `module.omni_host_contabo[0].null_resource.ensure_image` created
- DNS records `cp_stawi*` and `cpd_stawi*` show **in-place updates** (content flips from OCI ephemeral IPv4 to Contabo IPv4 via `local.omni_host_ipv4`)
- `random_uuid.omni_account_id` and `random_password.dex_omni_client_secret` are **unchanged** (proves Task 2's hoist worked)

If the random resources show changes: **stop**. Investigate state — the Task 2 state-mv likely failed.

- [ ] **Step 3: Commit (DO NOT APPLY YET — apply happens via PR-merge workflow)**

```bash
cd ../../..
git add tofu/layers/00-omni-server/terraform.tfvars
git commit -m "00-omni-server: flip omni_host_provider to contabo

Apply trigger for the omni→Contabo migration. Next tofu-apply on
00-omni-server destroys the OCI omni-host and creates the Contabo
omni-host on VPS 202727781 (which leaves the cluster pool via the
prior commit).

Apply order on merge:
  1. 02-oracle-infra (bwire cell): oci-bwire-node-1 destroyed +
     recreated at 4/24/180 worker spec (driven by R2 inventory).
  2. 01-contabo-infra (bwire cell): bwire-3 leaves cluster, bwire-2
     role flips to controlplane.
  3. 00-omni-server: oci omni-host destroyed, contabo omni-host
     created on VPS 202727781, DNS flips."
```

---

### Task 12: Open PR + pre-merge runbook

The code is ready. Pre-merge operator gates verify the OCI quota state and remind the operator of the irreversibility.

**Files:** none (operational)

- [ ] **Step 1: Push and open PR**

```bash
git push -u origin feat/omni-contabo-realignment
gh pr create --title "Realign cluster: omni-host + CP back to Contabo, OCI bwire to single worker" --body "$(cat <<'EOF'
## Summary
- Move omni-host + sole CP back to Contabo (driver: OCI public-IPv4 instability for stable-name endpoints).
- Consolidate OCI bwire compute: 2 small VMs → 1 4/24/180 worker (full Always-Free ARM quota).
- New parallel `tofu/modules/omni-host-contabo/` matches `omni-host-oci`'s output contract; substrate switches via `var.omni_host_provider`.
- Hoist `random_uuid.omni_account_id` + `random_password.dex_omni_client_secret` to layer scope so they survive substrate switches.

Spec: `docs/superpowers/specs/2026-05-03-omni-contabo-realignment-design.md`
Plan: `docs/superpowers/plans/2026-05-03-omni-contabo-realignment-plan.md`

## Pre-merge gates (operator)
- [ ] G0: `oci limits utilization-summary list --service-name compute --compartment-id <bwire>` shows ARM A1.Flex usage at 4 OCPU + 24 GB (current state) — confirms the destroy-recreate plan can re-claim its own quota.
- [ ] R2 inventory pre-staged: oracle/bwire (OCI worker spec bumped) and contabo/bwire (bwire-3 dropped, bwire-2 role flipped) — completed in Tasks 8 + 9.
- [ ] Cluster operator window scheduled (~30 min — omni unavailable during apply).

## Apply order on merge (workflow-driven)
1. `02-oracle-infra` (bwire cell): destroys old `oci-bwire-node-1`, recreates at 4/24/180.
2. `01-contabo-infra` (bwire cell): removes bwire-3 from cluster state (VPS untouched per Contabo no-destroy rule); bwire-2 role flips to controlplane.
3. `00-omni-server`: destroys OCI omni-host, creates Contabo omni-host on VPS 202727781; DNS flips.

## Post-merge verification (gates G3-G15 from spec)
- [ ] G3: `ssh ubuntu@bwire-3` shows Ubuntu LTS, `docker compose ps` shows omni stack running.
- [ ] G4: `curl -fsSL https://cp.stawi.org/healthz` returns 200.
- [ ] G5: `omnictl get connectionparams` returns `https://cpd.stawi.org`.
- [ ] G6: regenerate-talos-images auto-PR opens with new arm64 + amd64 artifacts.
- [ ] G7: `omnictl get machinestatus -l 'omni.sidero.dev/cluster=stawi'` shows 5 cluster machines.
- [ ] G9: `omnictl get machineset -o table` shows `cp 1/1, workers 4/4`.
- [ ] G11: `kubectl get nodes` shows 5 Ready.
- [ ] G14: `aws s3 ls s3://omni-backup-storage/` shows a snapshot within 1 hour.
- [ ] G15: `tofu plan -var omni_host_provider=oci` succeeds (proves OCI path still wired; do not apply).

## Rollback
Greenfield-degraded posture; rollback = forward-fix, or revert this PR + set `omni_host_provider = "oci"` and re-apply.

## Test plan
- See gate checklist above. The full grid is in the spec under "Test plan / verification gates".
EOF
)"
```

- [ ] **Step 2: Tag operator for review**

The PR contains an apply trigger; operator should review the merged plan before letting the workflow apply.

---

## Self-Review

After writing this plan, the following spec requirements have explicit task coverage:

| Spec requirement | Covered by |
|---|---|
| omni-host on Contabo (bwire-3) | Tasks 4-6 (module), Task 7 (wiring), Task 11 (switch) |
| CP on Contabo (bwire-2) | Task 9 (R2 inventory role flip) — applied by `01-contabo-infra` next run |
| `oci-bwire-node-1` 4/24/180 worker | Task 8 (R2 inventory) |
| LB labels: 3 OCI workers | Tasks 8 + 9 (R2 `lb` field on each) — alimbacho67 / brianelvis33 unchanged from prior state, verify per Task 8 step |
| CP `NoSchedule` taint | Standard Talos behaviour for `node-role.kubernetes.io/control-plane` label set by `node-contabo`'s `derived_labels` (line 102-104 of `node-contabo/main.tf`); no plan task needed |
| `omni-host-contabo` module parallel to `omni-host-oci` | Tasks 4-6 |
| Shared templates extracted | Task 3 |
| `random_uuid` / `random_password` hoisted | Task 2 |
| `var.omni_host_provider` switch | Task 7 |
| `Workers.size = 4` | Task 10 |
| bwire-3 dropped from contabo bootstrap | Task 9 |
| Storage / IAM unchanged | (no task — by design) |
| Apply sequencing (single PR, single window) | Task 11 commit message + Task 12 PR description |

**Outstanding unknowns flagged inline (not gaps, but require runtime verification by the implementing agent):**
- Task 5 step 3: whether `ensure-image.sh` consumes `USER_DATA` (script may need patching).
- Task 7 step 1 + 3: exact `contabo` provider attribute names + image-lookup module input names (read sibling files).
- Task 7 step 8: whether the existing `omni_host_oci` module call needs a `moved{}` block when `count` is added.

**LB label verification (Task 8):** the spec says alimbacho67 and brianelvis33 should both have `lb: true`. They were already in the LB pool per the staged 2026-05-02 spec (verify when running Task 8 — patch only if needed; otherwise no-op).

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-05-03-omni-contabo-realignment-plan.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?**
