# Tofu Reuse-or-Create and Talos Upgrade Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the broken hardcoded Contabo import path with an R2-backed inventory model that reuses existing instances, creates missing ones, persists per-node Talos machine configs to the state bucket, and performs in-place Talos upgrades when the pinned version changes. Close the Contabo credential-leak along the way.

**Architecture:** All per-provider/per-account state lives in `s3://cluster-tofu-state/production/inventory/<provider>/<account>/{auth,nodes,state,talos-state,machine-configs}.yaml`. A new `tofu/modules/node-state/` module encapsulates read/write. Layers 01/02 use dynamic `import` blocks keyed off stored instance IDs (fresh-create when absent). Layer 03 renders `machine-configs.yaml`, diffs `last_applied_version` vs `var.talos_version`, and runs `talosctl upgrade --preserve` on drift before applying config. SOPS (`carlpett/sops`) handles encryption with a plan-time validation fixture.

**Tech Stack:** OpenTofu 1.10, Cloudflare R2 (S3-compatible backend), `carlpett/sops` provider (v1.1.1+), `siderolabs/talos` (v0.11.0-beta.1 pinned), `contabo/contabo` (v0.1.42 pinned, known buggy — workarounds documented), `oracle/oci` (v8.10.0), `hashicorp/aws` (used only for its S3 object provider against R2), age encryption, `talosctl`, GitHub Actions, Python 3, bash.

**Spec:** [`docs/superpowers/specs/2026-04-23-tofu-reuse-or-create-and-talos-upgrade-design.md`](../specs/2026-04-23-tofu-reuse-or-create-and-talos-upgrade-design.md)

---

## ⚠ Prerequisite (operator action, NOT a coding task)

Before merging any code from this plan: **rotate the Contabo OAuth2 credentials** that are currently leaked in plaintext across every `tofu-apply` workflow run log (see spec §Problem). Deleting the affected runs via `gh run delete` and/or making the repo private is also recommended. This plan replaces the leak at its root but does not retroactively remove the exposure.

---

## File Structure

### New files

```
tofu/modules/node-state/                        # new module
├── main.tf                                     # read/write resources
├── variables.tf                                # inputs
├── outputs.tf                                  # decoded YAML outputs
└── versions.tf                                 # provider constraints

tofu/shared/sops-fixture.age.yaml               # plan-time SOPS health check fixture
tofu/shared/bootstrap/contabo-instance-ids.yaml # one-time fallback (deleted in cleanup phase)

scripts/seed-inventory.sh                       # R2 inventory/ bootstrap (CI-run)
scripts/seed-inventory.bats                     # tests for the seed script
scripts/talos-upgrade.sh                        # wraps `talosctl upgrade --preserve`
scripts/talos-upgrade.bats                      # tests for the upgrade wrapper
scripts/lib/inventory-yaml.py                   # shared YAML render helper used by seed-inventory.sh

testdata/node-state/                            # fixture tree for module plan-tests
├── inventory-empty/
├── inventory-steady/
├── inventory-version-bump/
└── inventory-sops-broken/

.github/workflows/tofu-plan-regression.yml      # zero-diff regression check
```

### Modified files

```
tofu/layers/00-talos-secrets/main.tf            # add sops_provider_healthy check
tofu/layers/01-contabo-infra/
├── main.tf                                     # read node-state, remove TF_VAR_contabo_accounts plumbing
├── imports.tf                                  # replaced with dynamic import driven by state.yaml
├── nodes.tf                                    # import provider creds from decrypted auth.yaml
├── variables.tf                                # remove contabo_accounts var
└── outputs.tf                                  # preserve existing downstream outputs

tofu/layers/02-oracle-infra/
├── main.tf                                     # mirror of layer 01 changes
└── variables.tf                                # remove oci_accounts JSON var

tofu/layers/02-onprem-infra/
├── main.tf                                     # read from node-state, write state.yaml
└── variables.tf                                # remove onprem_accounts JSON var

tofu/layers/03-talos/
├── configs.tf                                  # render into machine-configs.yaml
├── apply.tf                                    # talos_machine_configuration_apply now reads from module output
├── main.tf                                     # add upgrade detection + null_resource.talos_upgrade
└── outputs.tf                                  # publish paths to machine-configs.yaml in R2

.github/workflows/tofu-layer.yml                # drop TF_VAR_*_accounts env, add seed step, add SOPS_AGE_KEY wiring
scripts/render-cluster-config.py                # slim down: produce nodes.yaml files for seed, not aggregated JSON
```

### Deleted files (cleanup phase)

```
tofu/shared/bootstrap/contabo-instance-ids.yaml # once first apply succeeds
(any code paths reading TF_VAR_contabo_accounts / TF_VAR_oci_accounts / TF_VAR_onprem_accounts)
```

---

## Conventions for this plan

- Every code step shows the full contents of the file or hunk. No "similar to…" shortcuts.
- Every run command shows the working directory as the first comment.
- Every task ends with a single commit step. No batched commits across tasks.
- HCL examples target OpenTofu 1.10; do not downgrade to Terraform-compatible syntax.
- Before a subagent starts any task: read the spec file once for context, then read only the specific files the task touches.

---

## Phase 0 — Foundations

### Task 1: Pin the SOPS provider in every layer that will read or write encrypted files

**Files:**
- Modify: `tofu/layers/00-talos-secrets/versions.tf`
- Modify: `tofu/layers/01-contabo-infra/versions.tf`
- Modify: `tofu/layers/02-oracle-infra/versions.tf`
- Modify: `tofu/layers/02-onprem-infra/versions.tf`
- Modify: `tofu/layers/03-talos/versions.tf`

- [ ] **Step 1: Read each `versions.tf` so you know the exact existing block to extend**

Run: `grep -l required_providers tofu/layers/*/versions.tf`
Expected: prints the five paths above.

- [ ] **Step 2: Add the `sops` provider constraint to each layer's `required_providers`**

For each file above, inside `terraform { required_providers { ... } }`, add:

```hcl
sops = {
  source  = "carlpett/sops"
  version = "~> 1.1"
}
```

Also ensure the AWS provider is pinned (needed for the `aws_s3_object` read/write against R2) if it isn't already:

```hcl
aws = {
  source  = "hashicorp/aws"
  version = "~> 5.70"
}
```

- [ ] **Step 3: Validate each layer still parses**

Run (once per layer):
```bash
# cwd: tofu/layers/<layer>
tofu init -backend=false -upgrade && tofu validate
```
Expected: `Success! The configuration is valid.` for every layer.

- [ ] **Step 4: Commit**

```bash
git add tofu/layers/*/versions.tf
git commit -m "Pin carlpett/sops and hashicorp/aws providers in every layer"
```

---

### Task 2: Create the SOPS validation fixture

**Files:**
- Create: `tofu/shared/sops-fixture.age.yaml`
- Create: `tofu/shared/sops-fixture.plain.yaml` (committed for reference; NOT consumed by tofu)

- [ ] **Step 1: Read the existing age key reference**

The CI secret is `SOPS_AGE_KEY` (private) and maps to `TF_VAR_sops_age_key`; age recipients are the operator's public key(s). Identify the recipient(s) from the operator — for the plan, assume the variable `SOPS_AGE_RECIPIENT` (single recipient) plus any operator pubkeys committed elsewhere in the repo. If there is not yet a list of recipients on disk, create `tofu/shared/age-recipients.txt` with the CI recipient on a single line — the operator will add their own key in a later PR.

- [ ] **Step 2: Write the plaintext fixture**

File: `tofu/shared/sops-fixture.plain.yaml`
```yaml
# Plan-time SOPS provider health check fixture.
# If sops-fixture.age.yaml cannot be decrypted during `tofu plan`, the
# `sops_provider_healthy` check in each layer fails and the apply is blocked
# before any destructive action. Rotating age recipients requires updating
# this fixture (re-encrypt from this file) and committing both.
canary: healthy
```

- [ ] **Step 3: Encrypt the fixture to produce the committed artifact**

Run (interactively, from repo root):
```bash
export SOPS_AGE_RECIPIENTS="$(cat tofu/shared/age-recipients.txt)"
sops -e --input-type yaml --output-type yaml \
  tofu/shared/sops-fixture.plain.yaml > tofu/shared/sops-fixture.age.yaml
```
Expected: `sops-fixture.age.yaml` is a valid YAML file containing `sops:` metadata and an encrypted `canary` key.

- [ ] **Step 4: Verify round-trip decrypt works**

Run:
```bash
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt
sops -d tofu/shared/sops-fixture.age.yaml | grep -q 'canary: healthy'
```
Expected: exit status 0.

- [ ] **Step 5: Commit**

```bash
git add tofu/shared/age-recipients.txt tofu/shared/sops-fixture.plain.yaml tofu/shared/sops-fixture.age.yaml
git commit -m "Add SOPS provider validation fixture"
```

---

### Task 3: Wire the `sops_provider_healthy` check into every layer

**Files:**
- Create: `tofu/shared/sops-check.tf` (symlinked into each layer via Terraform's lack of symlink semantics means we copy — see Step 2 below)
- Modify: `tofu/layers/00-talos-secrets/sops-check.tf` (new)
- Modify: `tofu/layers/01-contabo-infra/sops-check.tf` (new)
- Modify: `tofu/layers/02-oracle-infra/sops-check.tf` (new)
- Modify: `tofu/layers/02-onprem-infra/sops-check.tf` (new)
- Modify: `tofu/layers/03-talos/sops-check.tf` (new)

OpenTofu does not read files from across layer boundaries at plan time (each layer is its own root module). The pragmatic path is a small generated file per layer with identical contents. A pre-commit hook `scripts/sync-sops-check.sh` will be added in Step 4 to keep them in sync.

- [ ] **Step 1: Write the source-of-truth file**

File: `tofu/shared/sops-check.tf.tmpl`
```hcl
# GENERATED — do not edit manually. Source: tofu/shared/sops-check.tf.tmpl
# Synced into each layer by scripts/sync-sops-check.sh (pre-commit).
#
# Fails plan if the SOPS provider cannot decrypt the validation fixture.
# Catches: stale age key in CI, recipient-set drift, missing SOPS_AGE_KEY env.
data "sops_file" "validation_fixture" {
  source_file = "${path.module}/../../shared/sops-fixture.age.yaml"
}

check "sops_provider_healthy" {
  assert {
    condition     = try(data.sops_file.validation_fixture.data["canary"], null) == "healthy"
    error_message = "SOPS provider cannot decrypt tofu/shared/sops-fixture.age.yaml. Check SOPS_AGE_KEY / TF_VAR_sops_age_key; do not proceed."
  }
}
```

- [ ] **Step 2: Create the sync script**

File: `scripts/sync-sops-check.sh`
```bash
#!/usr/bin/env bash
# Copies tofu/shared/sops-check.tf.tmpl into every layer as sops-check.tf.
# Run via pre-commit; also safe to run manually.
set -euo pipefail

SRC="$(git rev-parse --show-toplevel)/tofu/shared/sops-check.tf.tmpl"
LAYERS=(
  tofu/layers/00-talos-secrets
  tofu/layers/01-contabo-infra
  tofu/layers/02-oracle-infra
  tofu/layers/02-onprem-infra
  tofu/layers/03-talos
)

root="$(git rev-parse --show-toplevel)"
for layer in "${LAYERS[@]}"; do
  cp "$SRC" "$root/$layer/sops-check.tf"
done
```

Make it executable:
```bash
chmod +x scripts/sync-sops-check.sh
```

- [ ] **Step 3: Run the sync script to create the per-layer files**

```bash
./scripts/sync-sops-check.sh
```
Expected: five `sops-check.tf` files present, identical to the template.

- [ ] **Step 4: Add the sync to pre-commit**

Edit `.pre-commit-config.yaml` and add:
```yaml
  - repo: local
    hooks:
      - id: sync-sops-check
        name: sync SOPS health-check into every layer
        entry: scripts/sync-sops-check.sh
        language: system
        files: ^tofu/shared/sops-check\.tf\.tmpl$
        pass_filenames: false
```

- [ ] **Step 5: Validate every layer**

```bash
for layer in tofu/layers/{00-talos-secrets,01-contabo-infra,02-oracle-infra,02-onprem-infra,03-talos}; do
  ( cd "$layer" && tofu init -backend=false -upgrade >/dev/null && tofu validate ) || exit 1
done
```
Expected: `Success!` from every layer.

- [ ] **Step 6: Commit**

```bash
git add tofu/shared/sops-check.tf.tmpl scripts/sync-sops-check.sh \
        tofu/layers/*/sops-check.tf .pre-commit-config.yaml
git commit -m "Add SOPS plan-time health check to every layer"
```

---

### Task 4: Create `tofu/modules/node-state/` skeleton with inputs and outputs

**Files:**
- Create: `tofu/modules/node-state/versions.tf`
- Create: `tofu/modules/node-state/variables.tf`
- Create: `tofu/modules/node-state/outputs.tf`

- [ ] **Step 1: Write `versions.tf`**

File: `tofu/modules/node-state/versions.tf`
```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws  = { source = "hashicorp/aws",  version = "~> 5.70" }
    sops = { source = "carlpett/sops",  version = "~> 1.1" }
  }
}
```

- [ ] **Step 2: Write `variables.tf`**

File: `tofu/modules/node-state/variables.tf`
```hcl
variable "provider_name" {
  type        = string
  description = "Provider kind: contabo | oracle | onprem. 'provider' is reserved, hence the _name suffix."
  validation {
    condition     = contains(["contabo", "oracle", "onprem"], var.provider_name)
    error_message = "provider_name must be one of: contabo, oracle, onprem."
  }
}

variable "account" {
  type        = string
  description = "Account key. For on-prem this is the location key (e.g. savannah-hq)."
}

variable "bucket" {
  type        = string
  default     = "cluster-tofu-state"
  description = "R2 bucket holding the inventory tree."
}

variable "key_prefix" {
  type        = string
  default     = "production/inventory"
  description = "Key prefix under which inventory/<provider>/<account>/*.yaml live."
}

variable "age_recipients" {
  type        = list(string)
  description = "Age public keys to encrypt writes to. Reads use SOPS_AGE_KEY from env."
}

variable "write_auth" {
  type    = bool
  default = false
}
variable "write_nodes" {
  type    = bool
  default = false
}
variable "write_state" {
  type    = bool
  default = false
}
variable "write_talos_state" {
  type    = bool
  default = false
}
variable "write_machine_configs" {
  type    = bool
  default = false
}

variable "auth_content"            { type = any, default = null }
variable "nodes_content"           { type = any, default = null }
variable "state_content"           { type = any, default = null }
variable "talos_state_content"     { type = any, default = null }
variable "machine_configs_content" { type = any, default = null }
```

- [ ] **Step 3: Write `outputs.tf` (empty bodies for now — fleshed out in Task 5)**

File: `tofu/modules/node-state/outputs.tf`
```hcl
output "auth"            { value = local.auth_decoded }
output "nodes"           { value = local.nodes_decoded }
output "state"           { value = local.state_decoded }
output "talos_state"     { value = local.talos_state_decoded }
output "machine_configs" { value = local.machine_configs_decoded }
```

- [ ] **Step 4: Commit**

```bash
git add tofu/modules/node-state/versions.tf tofu/modules/node-state/variables.tf tofu/modules/node-state/outputs.tf
git commit -m "Scaffold node-state module variables and outputs"
```

---

### Task 5: Implement `node-state` module read logic

**Files:**
- Create: `tofu/modules/node-state/main.tf`

- [ ] **Step 1: Write the read half of main.tf**

File: `tofu/modules/node-state/main.tf` (first half; writers added in Task 6)
```hcl
# tofu/modules/node-state/main.tf
#
# Reads five inventory files for (provider, account) from R2 and exposes
# decoded YAML. Missing files return {} so callers on first apply see an
# empty state and create-from-scratch.
#
# Encrypted files (auth.yaml, machine-configs.yaml) are decrypted via the
# carlpett/sops provider using SOPS_AGE_KEY from the environment.

locals {
  base_key = "${var.key_prefix}/${var.provider_name}/${var.account}"

  auth_key            = "${local.base_key}/auth.yaml"
  nodes_key           = "${local.base_key}/nodes.yaml"
  state_key           = "${local.base_key}/state.yaml"
  talos_state_key     = "${local.base_key}/talos-state.yaml"
  machine_configs_key = "${local.base_key}/machine-configs.yaml"
}

# --- plaintext reads -------------------------------------------------------

data "aws_s3_object" "nodes" {
  bucket = var.bucket
  key    = local.nodes_key
}

data "aws_s3_object" "state" {
  bucket = var.bucket
  key    = local.state_key
}

data "aws_s3_object" "talos_state" {
  bucket = var.bucket
  key    = local.talos_state_key
}

# --- encrypted reads (auth + machine-configs) ------------------------------
# aws_s3_object fetches the raw encrypted bytes; we write them to a local
# file so sops_file can point at them. local_sensitive_file isolates the
# plaintext from normal `tofu show`.

data "aws_s3_object" "auth_raw" {
  count  = var.provider_name == "contabo" ? 1 : 0
  bucket = var.bucket
  key    = local.auth_key
}

data "aws_s3_object" "machine_configs_raw" {
  bucket = var.bucket
  key    = local.machine_configs_key
}

locals {
  auth_raw_body = (
    var.provider_name == "contabo"
    ? try(data.aws_s3_object.auth_raw[0].body, "")
    : try(data.aws_s3_object.auth_raw_plain[0].body, "")
  )
  machine_configs_raw_body = try(data.aws_s3_object.machine_configs_raw.body, "")
}

# Non-contabo auth is plaintext.
data "aws_s3_object" "auth_raw_plain" {
  count  = var.provider_name == "contabo" ? 0 : 1
  bucket = var.bucket
  key    = local.auth_key
}

# Stage encrypted bodies to disk so sops_file can decrypt them.
resource "local_sensitive_file" "auth_staged" {
  count    = var.provider_name == "contabo" && local.auth_raw_body != "" ? 1 : 0
  filename = "${path.module}/.staged/auth-${var.provider_name}-${var.account}.age.yaml"
  content  = local.auth_raw_body
}

resource "local_sensitive_file" "machine_configs_staged" {
  count    = local.machine_configs_raw_body != "" ? 1 : 0
  filename = "${path.module}/.staged/machine-configs-${var.provider_name}-${var.account}.age.yaml"
  content  = local.machine_configs_raw_body
}

data "sops_file" "auth" {
  count       = var.provider_name == "contabo" && local.auth_raw_body != "" ? 1 : 0
  source_file = local_sensitive_file.auth_staged[0].filename
}

data "sops_file" "machine_configs" {
  count       = local.machine_configs_raw_body != "" ? 1 : 0
  source_file = local_sensitive_file.machine_configs_staged[0].filename
}

# --- decoded outputs -------------------------------------------------------

locals {
  auth_decoded = (
    var.provider_name == "contabo"
    ? try(yamldecode(data.sops_file.auth[0].raw), null)
    : try(yamldecode(data.aws_s3_object.auth_raw_plain[0].body), null)
  )

  nodes_decoded = try(
    yamldecode(data.aws_s3_object.nodes.body),
    { nodes = {} }
  )

  state_decoded = try(
    yamldecode(data.aws_s3_object.state.body),
    { nodes = {} }
  )

  talos_state_decoded = try(
    yamldecode(data.aws_s3_object.talos_state.body),
    { nodes = {} }
  )

  machine_configs_decoded = try(
    yamldecode(data.sops_file.machine_configs[0].raw),
    { nodes = {} }
  )
}
```

- [ ] **Step 2: Also add the `hashicorp/local` provider to versions.tf**

Append to `tofu/modules/node-state/versions.tf` `required_providers`:
```hcl
local = { source = "hashicorp/local", version = "~> 2.5" }
```

- [ ] **Step 3: Validate**

```bash
# cwd: tofu/modules/node-state
tofu init -backend=false -upgrade >/dev/null && tofu validate
```
Expected: `Success!`.

- [ ] **Step 4: Commit**

```bash
git add tofu/modules/node-state/main.tf tofu/modules/node-state/versions.tf
git commit -m "Implement node-state module read path"
```

---

### Task 6: Implement `node-state` module write logic

**Files:**
- Modify: `tofu/modules/node-state/main.tf` (append writer resources)

- [ ] **Step 1: Append the writer block to main.tf**

Add to the bottom of `tofu/modules/node-state/main.tf`:
```hcl
# --- encrypted writers -----------------------------------------------------
# Encrypt via sops::encrypt (OpenTofu 1.8+ provider-defined function) then
# PUT to R2. The sha256 suffix in the key forces PutObject only when content
# actually changed (etag comparison is handled by the provider).

locals {
  recipients_joined = join(",", var.age_recipients)
}

resource "aws_s3_object" "auth" {
  count  = var.write_auth && var.provider_name == "contabo" ? 1 : 0
  bucket = var.bucket
  key    = local.auth_key
  content = provider::sops::encrypt(
    yamlencode(var.auth_content),
    "yaml",
    { age = local.recipients_joined },
  )
  content_type = "application/x-yaml"
}

resource "aws_s3_object" "auth_plaintext" {
  count        = var.write_auth && var.provider_name != "contabo" ? 1 : 0
  bucket       = var.bucket
  key          = local.auth_key
  content      = yamlencode(var.auth_content)
  content_type = "application/x-yaml"
}

resource "aws_s3_object" "nodes" {
  count        = var.write_nodes ? 1 : 0
  bucket       = var.bucket
  key          = local.nodes_key
  content      = yamlencode(var.nodes_content)
  content_type = "application/x-yaml"
}

resource "aws_s3_object" "state" {
  count        = var.write_state ? 1 : 0
  bucket       = var.bucket
  key          = local.state_key
  content      = yamlencode(var.state_content)
  content_type = "application/x-yaml"
}

resource "aws_s3_object" "talos_state" {
  count        = var.write_talos_state ? 1 : 0
  bucket       = var.bucket
  key          = local.talos_state_key
  content      = yamlencode(var.talos_state_content)
  content_type = "application/x-yaml"
}

resource "aws_s3_object" "machine_configs" {
  count  = var.write_machine_configs ? 1 : 0
  bucket = var.bucket
  key    = local.machine_configs_key
  content = provider::sops::encrypt(
    yamlencode(var.machine_configs_content),
    "yaml",
    { age = local.recipients_joined },
  )
  content_type = "application/x-yaml"
}
```

- [ ] **Step 2: Guard against stale writes — require non-null content when `write_*` is true**

Add preconditions. Append to `variables.tf`:
```hcl
# (no new variables — preconditions live on the resources themselves)
```
And add to each writer resource a `lifecycle { precondition { ... } }` block, e.g. for `nodes`:
```hcl
  lifecycle {
    precondition {
      condition     = var.nodes_content != null
      error_message = "write_nodes = true but nodes_content is null"
    }
  }
```
Mirror the precondition on the other four writers, adjusting the variable reference.

- [ ] **Step 3: Validate**

```bash
# cwd: tofu/modules/node-state
tofu validate
```
Expected: `Success!`.

- [ ] **Step 4: Commit**

```bash
git add tofu/modules/node-state/main.tf
git commit -m "Implement node-state module write path"
```

---

### Task 7: Create the Contabo bootstrap fallback file

**Files:**
- Create: `tofu/shared/bootstrap/contabo-instance-ids.yaml`

- [ ] **Step 1: Capture the current hardcoded IDs**

Read `tofu/layers/01-contabo-infra/imports.tf` — the map `existing_contabo_instance_ids` has three entries. Copy them verbatim.

- [ ] **Step 2: Write the bootstrap file**

File: `tofu/shared/bootstrap/contabo-instance-ids.yaml`
```yaml
# One-time bootstrap fallback for scripts/seed-inventory.sh.
#
# Used ONLY when seed-inventory.sh cannot resolve a Contabo node's live
# instance ID by display_name (e.g. Contabo API transient error, multiple
# matches per provider bug #40). Delete this file after the first successful
# apply populates production/inventory/contabo/*/state.yaml in R2.
#
# Format matches the `nodes[<key>].provider_data` sub-schema of state.yaml.
contabo:
  stawi-contabo:
    kubernetes-controlplane-api-1:
      contabo_instance_id: "202727783"
    kubernetes-controlplane-api-2:
      contabo_instance_id: "202727782"
    kubernetes-controlplane-api-3:
      contabo_instance_id: "202727781"
```

- [ ] **Step 3: Commit**

```bash
git add tofu/shared/bootstrap/contabo-instance-ids.yaml
git commit -m "Seed bootstrap fallback with current Contabo instance IDs"
```

---

### Task 8: Write `scripts/talos-upgrade.sh` + tests

**Files:**
- Create: `scripts/talos-upgrade.sh`
- Create: `scripts/talos-upgrade.bats`

- [ ] **Step 1: Write the failing test first**

File: `scripts/talos-upgrade.bats`
```bash
#!/usr/bin/env bats
# Tests for scripts/talos-upgrade.sh

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"

  cat >"$FAKE_BIN/talosctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  upgrade) echo "upgrade called: $*" ; exit 0 ;;
  version) echo "Server:" ; echo "  Tag: $TALOS_FAKE_VERSION" ;;
  *) echo "unexpected talosctl arg: $*" >&2 ; exit 2 ;;
esac
FAKE
  chmod +x "$FAKE_BIN/talosctl"
}

@test "errors when required env vars are missing" {
  run scripts/talos-upgrade.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"NODE is required"* ]]
}

@test "runs talosctl upgrade with --preserve" {
  export NODE=10.0.0.1
  export TALOSCONFIG=/dev/null
  export IMAGE=factory.talos.dev/installer/abc:v1.12.6
  export TALOS_FAKE_VERSION=v1.12.6
  run scripts/talos-upgrade.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"upgrade called"* ]]
  [[ "$output" == *"--preserve"* ]]
  [[ "$output" == *"--image=factory.talos.dev/installer/abc:v1.12.6"* ]]
  [[ "$output" == *"--nodes=10.0.0.1"* ]]
}

@test "fails when post-upgrade version does not match" {
  export NODE=10.0.0.1
  export TALOSCONFIG=/dev/null
  export IMAGE=factory.talos.dev/installer/abc:v1.12.6
  export TALOS_FAKE_VERSION=v1.12.5
  export EXPECT_VERSION=v1.12.6
  run scripts/talos-upgrade.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"version mismatch"* ]]
}
```

- [ ] **Step 2: Run the test — expect failure (script doesn't exist)**

```bash
bats scripts/talos-upgrade.bats
```
Expected: all three tests FAIL with "scripts/talos-upgrade.sh: No such file or directory".

- [ ] **Step 3: Write the script**

File: `scripts/talos-upgrade.sh`
```bash
#!/usr/bin/env bash
# Runs `talosctl upgrade --preserve` against a single node, waits for the
# Talos API to come back up, then verifies the installed version matches
# $EXPECT_VERSION (defaults to the tag portion of $IMAGE).
#
# Required env: NODE, TALOSCONFIG, IMAGE
# Optional env: EXPECT_VERSION, STAGE (set to "true" to pass --stage)
set -euo pipefail

: "${NODE:?NODE is required}"
: "${TALOSCONFIG:?TALOSCONFIG is required}"
: "${IMAGE:?IMAGE is required}"

EXPECT_VERSION="${EXPECT_VERSION:-${IMAGE##*:}}"
STAGE_ARG=()
if [[ "${STAGE:-false}" == "true" ]]; then
  STAGE_ARG=(--stage)
fi

echo "[talos-upgrade] node=$NODE image=$IMAGE expect=$EXPECT_VERSION"

talosctl \
  --talosconfig "$TALOSCONFIG" \
  upgrade \
  "${STAGE_ARG[@]}" \
  --preserve \
  --image="$IMAGE" \
  --nodes="$NODE"

# Wait up to 10 minutes for the API to return a matching version.
for attempt in $(seq 1 60); do
  if OUT=$(talosctl --talosconfig "$TALOSCONFIG" version --nodes "$NODE" 2>/dev/null); then
    CUR=$(echo "$OUT" | awk '/^[[:space:]]*Tag:/ {print $2; exit}')
    if [[ "$CUR" == "$EXPECT_VERSION" ]]; then
      echo "[talos-upgrade] success (tag=$CUR)"
      exit 0
    fi
  fi
  sleep 10
done

echo "[talos-upgrade] version mismatch after 10m: wanted $EXPECT_VERSION, got ${CUR:-unknown}" >&2
exit 1
```

Make executable:
```bash
chmod +x scripts/talos-upgrade.sh
```

- [ ] **Step 4: Run tests — expect pass**

```bash
bats scripts/talos-upgrade.bats
```
Expected: all three tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/talos-upgrade.sh scripts/talos-upgrade.bats
git commit -m "Add talos-upgrade.sh wrapper with tests"
```

---

### Task 9: Write the shared YAML render helper used by `seed-inventory.sh`

**Files:**
- Create: `scripts/lib/inventory_yaml.py`
- Create: `scripts/lib/test_inventory_yaml.py`

- [ ] **Step 1: Write the failing test first**

File: `scripts/lib/test_inventory_yaml.py`
```python
"""Tests for scripts/lib/inventory_yaml.py — deterministic YAML rendering."""
import pytest
from inventory_yaml import render_nodes_yaml, render_state_yaml, merge_state


def test_render_nodes_yaml_sorted_keys():
    out = render_nodes_yaml(
        provider="contabo",
        account="stawi-contabo",
        account_meta={"labels": {"x": "1"}, "annotations": {}},
        nodes={"b-node": {"role": "worker"}, "a-node": {"role": "controlplane"}},
    )
    assert out.index("a-node") < out.index("b-node")
    assert out.startswith("account: stawi-contabo\n")


def test_render_state_yaml_with_provider_data():
    out = render_state_yaml(
        provider="contabo",
        account="stawi-contabo",
        node_provider_data={
            "api-1": {"contabo_instance_id": "202727783", "ipv4": "1.2.3.4"},
        },
    )
    assert "contabo_instance_id: '202727783'" in out or 'contabo_instance_id: "202727783"' in out


def test_merge_state_preserves_existing_subtree():
    existing = {"nodes": {"api-1": {"talos_state": {"last_applied_version": "v1.12.5"}}}}
    incoming = {"nodes": {"api-1": {"provider_data": {"ipv4": "1.2.3.4"}}}}
    merged = merge_state(existing, incoming)
    assert merged["nodes"]["api-1"]["talos_state"]["last_applied_version"] == "v1.12.5"
    assert merged["nodes"]["api-1"]["provider_data"]["ipv4"] == "1.2.3.4"
```

- [ ] **Step 2: Run the test — expect failure**

```bash
# cwd: scripts/lib
python3 -m pytest test_inventory_yaml.py -v
```
Expected: FAIL with `ModuleNotFoundError: No module named 'inventory_yaml'`.

- [ ] **Step 3: Write the module**

File: `scripts/lib/inventory_yaml.py`
```python
"""Deterministic YAML rendering for the R2 inventory tree."""
from __future__ import annotations

from copy import deepcopy
from typing import Any, Mapping

import yaml


class _SortedDumper(yaml.SafeDumper):
    """Dumps mappings with sorted keys and wide column width for readability."""


def _represent_dict(dumper: yaml.SafeDumper, data: Mapping[str, Any]):
    return dumper.represent_mapping(
        "tag:yaml.org,2002:map", sorted(data.items(), key=lambda kv: kv[0])
    )


_SortedDumper.add_representer(dict, _represent_dict)


def _dump(obj: Any) -> str:
    return yaml.dump(obj, Dumper=_SortedDumper, default_flow_style=False, sort_keys=False, width=100)


def render_nodes_yaml(provider: str, account: str, account_meta: Mapping, nodes: Mapping) -> str:
    payload = {
        "provider": provider,
        "account": account,
        "labels": dict(account_meta.get("labels", {})),
        "annotations": dict(account_meta.get("annotations", {})),
        "nodes": {k: dict(v) for k, v in nodes.items()},
    }
    return _dump(payload)


def render_state_yaml(provider: str, account: str, node_provider_data: Mapping[str, Mapping]) -> str:
    payload = {
        "provider": provider,
        "account": account,
        "nodes": {k: {"provider_data": dict(v)} for k, v in node_provider_data.items()},
    }
    return _dump(payload)


def merge_state(existing: Mapping, incoming: Mapping) -> dict:
    """Deep-merge inventory YAMLs without losing sibling subtrees."""
    merged = deepcopy(dict(existing)) if existing else {}
    if "nodes" not in merged:
        merged["nodes"] = {}
    for k, v in (incoming.get("nodes") or {}).items():
        merged["nodes"].setdefault(k, {})
        for sub_k, sub_v in v.items():
            merged["nodes"][k][sub_k] = deepcopy(sub_v)
    for top_k, top_v in incoming.items():
        if top_k != "nodes":
            merged[top_k] = deepcopy(top_v)
    return merged
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd scripts/lib && python3 -m pytest test_inventory_yaml.py -v
```
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/inventory_yaml.py scripts/lib/test_inventory_yaml.py
git commit -m "Add deterministic YAML renderer for the inventory tree"
```

---

### Task 10: Write `scripts/seed-inventory.sh` + tests

**Files:**
- Create: `scripts/seed-inventory.sh`
- Create: `scripts/seed-inventory.bats`

- [ ] **Step 1: Write the failing tests**

File: `scripts/seed-inventory.bats`
```bash
#!/usr/bin/env bats

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export INVENTORY_ROOT="$BATS_TEST_TMPDIR/inventory"
  export BOOTSTRAP_FILE="$BATS_TEST_TMPDIR/bootstrap.yaml"

  # Stubs: contabo-cli and oci-cli replaced with deterministic fakes.
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"
  cat >"$FAKE_BIN/contabo-list" <<'FAKE'
#!/usr/bin/env bash
# Returns JSON: { "instances": [ { "instanceId": 99, "displayName": "already-here" } ] }
echo '{"instances":[{"instanceId":99,"displayName":"already-here","ipConfig":{"v4":[{"ip":"1.2.3.4"}],"v6":[{"ip":"2a02::1"}]}}]}'
FAKE
  chmod +x "$FAKE_BIN/contabo-list"

  cat >"$BOOTSTRAP_FILE" <<'YAML'
contabo:
  acct:
    missing-node: { contabo_instance_id: "42" }
YAML
}

@test "seed writes nodes.yaml and state.yaml per account" {
  run scripts/seed-inventory.sh \
    --dry-run \
    --output-dir "$INVENTORY_ROOT" \
    --bootstrap "$BOOTSTRAP_FILE" \
    --contabo-account acct \
    --contabo-node already-here \
    --contabo-node missing-node \
    --contabo-list-cmd contabo-list

  [ "$status" -eq 0 ]
  [ -f "$INVENTORY_ROOT/contabo/acct/nodes.yaml" ]
  [ -f "$INVENTORY_ROOT/contabo/acct/state.yaml" ]
  grep -q "contabo_instance_id: '99'" "$INVENTORY_ROOT/contabo/acct/state.yaml"
  grep -q "contabo_instance_id: '42'" "$INVENTORY_ROOT/contabo/acct/state.yaml"
}

@test "seed is idempotent on re-run" {
  scripts/seed-inventory.sh --dry-run \
    --output-dir "$INVENTORY_ROOT" --bootstrap "$BOOTSTRAP_FILE" \
    --contabo-account acct --contabo-node already-here \
    --contabo-list-cmd contabo-list
  before=$(sha256sum "$INVENTORY_ROOT/contabo/acct/state.yaml" | awk '{print $1}')
  scripts/seed-inventory.sh --dry-run \
    --output-dir "$INVENTORY_ROOT" --bootstrap "$BOOTSTRAP_FILE" \
    --contabo-account acct --contabo-node already-here \
    --contabo-list-cmd contabo-list
  after=$(sha256sum "$INVENTORY_ROOT/contabo/acct/state.yaml" | awk '{print $1}')
  [ "$before" = "$after" ]
}
```

- [ ] **Step 2: Run — expect failure (script absent)**

```bash
bats scripts/seed-inventory.bats
```
Expected: FAIL with "No such file or directory".

- [ ] **Step 3: Write the script**

File: `scripts/seed-inventory.sh`
```bash
#!/usr/bin/env bash
# Seeds the R2 inventory/ tree for the first apply.
#
# Modes:
#   --dry-run   : write to --output-dir instead of R2 (used by tests & CI preview)
#   (default)   : sync to s3://cluster-tofu-state/production/inventory/
#
# Per invocation handles a single provider/account. The GitHub Actions
# workflow loops over all providers/accounts declared in repo metadata.
#
# Flags:
#   --output-dir PATH         dry-run destination root
#   --bootstrap PATH          fallback instance IDs (YAML)
#   --contabo-account ACCT    account key
#   --contabo-node NAME       repeatable
#   --contabo-list-cmd CMD    command that prints Contabo instances JSON (for tests)
#   --oci-account ACCT        (mirrors contabo)
#   --oci-node NAME
#   --oci-list-cmd CMD
set -euo pipefail

usage() { sed -n '2,20p' "$0"; exit 2; }

DRY_RUN=false
OUTDIR=""
BOOTSTRAP=""
CONTABO_ACCT=""
CONTABO_NODES=()
CONTABO_LIST_CMD=""
OCI_ACCT=""
OCI_NODES=()
OCI_LIST_CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --output-dir) OUTDIR=$2; shift 2 ;;
    --bootstrap) BOOTSTRAP=$2; shift 2 ;;
    --contabo-account) CONTABO_ACCT=$2; shift 2 ;;
    --contabo-node) CONTABO_NODES+=("$2"); shift 2 ;;
    --contabo-list-cmd) CONTABO_LIST_CMD=$2; shift 2 ;;
    --oci-account) OCI_ACCT=$2; shift 2 ;;
    --oci-node) OCI_NODES+=("$2"); shift 2 ;;
    --oci-list-cmd) OCI_LIST_CMD=$2; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown flag: $1" >&2; usage ;;
  esac
done

here="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="$here/lib${PYTHONPATH+:$PYTHONPATH}"

seed_contabo() {
  local acct=$1
  shift
  local wanted=("$@")
  local list_json
  list_json=$("$CONTABO_LIST_CMD")
  python3 - "$acct" "$BOOTSTRAP" "$OUTDIR" <<'PY' "${wanted[@]}" <<<"$list_json"
import json, os, sys, yaml
from inventory_yaml import render_nodes_yaml, render_state_yaml

acct, bootstrap_path, outdir, *wanted = sys.argv[1:]
instances = json.load(sys.stdin)["instances"]
by_name = {}
for inst in instances:
    by_name.setdefault(inst["displayName"], []).append(inst)
resolved = {}
for name in wanted:
    matches = by_name.get(name, [])
    if len(matches) == 1:
        resolved[name] = {
            "contabo_instance_id": str(matches[0]["instanceId"]),
            "ipv4": matches[0].get("ipConfig", {}).get("v4", [{}])[0].get("ip"),
            "ipv6": matches[0].get("ipConfig", {}).get("v6", [{}])[0].get("ip"),
        }
    elif len(matches) > 1:
        print(f"ERROR: multiple Contabo instances match {name!r}. Disambiguate manually.", file=sys.stderr)
        sys.exit(3)
    else:
        if bootstrap_path and os.path.exists(bootstrap_path):
            data = yaml.safe_load(open(bootstrap_path)) or {}
            fallback = data.get("contabo", {}).get(acct, {}).get(name)
            if fallback:
                resolved[name] = fallback
                continue
        print(f"ERROR: Contabo node {name!r} not resolvable by name or bootstrap.", file=sys.stderr)
        sys.exit(4)

base = os.path.join(outdir, "contabo", acct)
os.makedirs(base, exist_ok=True)
open(os.path.join(base, "nodes.yaml"), "w").write(
    render_nodes_yaml("contabo", acct, {"labels": {}, "annotations": {}},
                      {name: {"role": "controlplane"} for name in wanted})
)
open(os.path.join(base, "state.yaml"), "w").write(
    render_state_yaml("contabo", acct, resolved)
)
PY
}

[[ -n "$CONTABO_ACCT" ]] && seed_contabo "$CONTABO_ACCT" "${CONTABO_NODES[@]}"

if [[ "$DRY_RUN" == false ]]; then
  : "${R2_ENDPOINT_URL:?R2_ENDPOINT_URL required for non-dry-run}"
  aws s3 sync "$OUTDIR" "s3://cluster-tofu-state/production/inventory/" \
    --endpoint-url "$R2_ENDPOINT_URL" --region us-east-1
fi
```

Make executable:
```bash
chmod +x scripts/seed-inventory.sh
```

- [ ] **Step 4: Run tests — expect pass**

```bash
bats scripts/seed-inventory.bats
```
Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/seed-inventory.sh scripts/seed-inventory.bats
git commit -m "Add seed-inventory.sh bootstrap script with tests"
```

---

## Phase 1 — Wire layer 01 (Contabo)

### Task 11: Read Contabo auth/nodes/state from R2 via the `node-state` module (no behavior change yet)

**Files:**
- Modify: `tofu/layers/01-contabo-infra/main.tf`

- [ ] **Step 1: Add the module instantiation without wiring it in**

Append to `tofu/layers/01-contabo-infra/main.tf`:
```hcl
# node-state: R2-backed inventory read. Populated initially by
# scripts/seed-inventory.sh; kept in sync by this layer's writers.
module "contabo_account_state" {
  for_each      = toset(local.contabo_account_keys)
  source        = "../../modules/node-state"
  provider_name = "contabo"
  account       = each.key
  age_recipients = split(",", var.age_recipients)
}

locals {
  contabo_account_keys = keys(var.contabo_accounts)

  # Short-term: we still read from TF_VAR_contabo_accounts. After Task 14
  # we switch to module.contabo_account_state[*].auth. The two locals
  # below exist to make that switch a one-line diff.
  contabo_auth_from_module = {
    for k, mod in module.contabo_account_state :
      k => try(mod.auth.auth, null)
  }
  contabo_nodes_from_module = {
    for k, mod in module.contabo_account_state :
      k => try(mod.nodes.nodes, {})
  }
  contabo_state_from_module = {
    for k, mod in module.contabo_account_state :
      k => try(mod.state.nodes, {})
  }
}
```

Also add to `variables.tf`:
```hcl
variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}
```

- [ ] **Step 2: Validate**

```bash
# cwd: tofu/layers/01-contabo-infra
tofu init -backend=false -upgrade >/dev/null && tofu validate
```
Expected: `Success!`.

- [ ] **Step 3: Commit**

```bash
git add tofu/layers/01-contabo-infra/main.tf tofu/layers/01-contabo-infra/variables.tf
git commit -m "Instantiate node-state module in layer 01 (no behavior change)"
```

---

### Task 12: Replace `imports.tf` with dynamic imports driven by `state.yaml`

**Files:**
- Modify: `tofu/layers/01-contabo-infra/imports.tf`

- [ ] **Step 1: Rewrite imports.tf end-to-end**

File: `tofu/layers/01-contabo-infra/imports.tf` (replace entire contents)
```hcl
# tofu/layers/01-contabo-infra/imports.tf
#
# Dynamic imports driven by production/inventory/contabo/<acct>/state.yaml.
# Key is set-only to the subset of nodes that *already have* a resolved
# instance ID in state.yaml — missing-state nodes plan as `create`.
#
# After apply, state.yaml is written back by this layer (see state-writer.tf),
# so the next plan sees the full set and produces a zero-diff.

locals {
  # Flat { "<node_key>" = "<instance_id>" } across all Contabo accounts.
  contabo_existing_instance_ids = merge([
    for acct_key, node_map in local.contabo_state_from_module : {
      for node_key, node in node_map :
        node_key => try(node.provider_data.contabo_instance_id, null)
        if try(node.provider_data.contabo_instance_id, null) != null
    }
  ]...)
}

import {
  for_each = local.contabo_existing_instance_ids
  to       = module.nodes[each.key].contabo_instance.this
  id       = each.value
}
```

- [ ] **Step 2: Validate**

```bash
# cwd: tofu/layers/01-contabo-infra
tofu validate
```
Expected: `Success!`. (We can't run plan yet without real R2 credentials; that happens in Task 22.)

- [ ] **Step 3: Commit**

```bash
git add tofu/layers/01-contabo-infra/imports.tf
git commit -m "Drive Contabo imports from state.yaml instead of hardcoded IDs"
```

---

### Task 13: Write `state.yaml` back after apply

**Files:**
- Create: `tofu/layers/01-contabo-infra/state-writer.tf`

- [ ] **Step 1: Write the writer module instantiations**

File: `tofu/layers/01-contabo-infra/state-writer.tf`
```hcl
# tofu/layers/01-contabo-infra/state-writer.tf
#
# One writer module per Contabo account. `state_content` captures what we
# observed about each node's provider-side state; layer 03 owns talos_state
# in its own sibling file (talos-state.yaml).

module "contabo_account_state_writer" {
  for_each      = toset(local.contabo_account_keys)
  source        = "../../modules/node-state"
  provider_name = "contabo"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_state = true
  state_content = {
    provider = "contabo"
    account  = each.key
    nodes = {
      for node_key, node_module in module.nodes :
        node_key => {
          provider_data = {
            contabo_instance_id = node_module.instance_id
            product_id          = node_module.product_id
            region              = node_module.region
            ipv4                = node_module.ipv4
            ipv6                = node_module.ipv6
            status              = "running"
            discovered_at       = timestamp()
          }
        }
        if node_module.account_key == each.key
    }
  }

  depends_on = [module.nodes]
}
```

- [ ] **Step 2: Ensure `module.nodes` exposes the attributes used above**

Open `tofu/modules/node-contabo/outputs.tf` and ensure the following outputs exist (add any that are missing):
```hcl
output "instance_id" { value = contabo_instance.this.id }
output "product_id"  { value = contabo_instance.this.product_id }
output "region"      { value = contabo_instance.this.region }
output "ipv4"        { value = local.ipv4 }
output "ipv6"        { value = local.ipv6 }
output "account_key" { value = var.account_key }
```
(If any existed already, leave them; add only the missing ones.)

- [ ] **Step 3: Validate**

```bash
# cwd: tofu/layers/01-contabo-infra
tofu validate
```
Expected: `Success!`.

- [ ] **Step 4: Commit**

```bash
git add tofu/layers/01-contabo-infra/state-writer.tf tofu/modules/node-contabo/outputs.tf
git commit -m "Write Contabo state.yaml back to R2 after apply"
```

---

### Task 14: Add `tofu/shared/accounts.yaml` manifest + loader locals in every layer

(This task used to be numbered 15 — promoted because Task 15/old-14 depends on the manifest existing.)

**Files:**
- Create: `tofu/shared/accounts.yaml`
- Modify: `tofu/layers/01-contabo-infra/main.tf`
- Modify: `tofu/layers/02-oracle-infra/main.tf`
- Modify: `tofu/layers/02-onprem-infra/main.tf`
- Modify: `tofu/layers/03-talos/main.tf`

- [ ] **Step 1: Write the manifest**

File: `tofu/shared/accounts.yaml`
```yaml
# Declares which provider/account keys exist. The node-state module uses
# these to know which R2 keys to read. Edit this file to onboard a new
# account; the inventory tree is seeded separately by seed-inventory.sh.
contabo:
  - stawi-contabo
oracle:
  - stawi
onprem:
  - savannah-hq
```

- [ ] **Step 2: Load it in each layer**

Add to each layer's `main.tf` (top-level):
```hcl
locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}
```

- [ ] **Step 3: Validate every affected layer**

```bash
for layer in 01-contabo-infra 02-oracle-infra 02-onprem-infra 03-talos; do
  ( cd "tofu/layers/$layer" && tofu init -backend=false -upgrade >/dev/null && tofu validate ) || exit 1
done
```
Expected: `Success!` from every layer.

- [ ] **Step 4: Commit**

```bash
git add tofu/shared/accounts.yaml tofu/layers/*/main.tf
git commit -m "Add accounts.yaml manifest and wire it into every layer"
```

---

### Task 15: Switch layer 01 to source auth from R2 instead of `TF_VAR_contabo_accounts`

**Files:**
- Modify: `tofu/layers/01-contabo-infra/main.tf`
- Modify: `tofu/layers/01-contabo-infra/nodes.tf`
- Modify: `tofu/layers/01-contabo-infra/variables.tf`
- Modify: `tofu/layers/01-contabo-infra/image.tf`

- [ ] **Step 1: Replace `var.contabo_accounts` references with module outputs**

In `main.tf`, the `locals` block that defines `contabo_accounts_effective` becomes:
```hcl
locals {
  contabo_accounts_effective = {
    for acct_key in local.contabo_account_keys : acct_key => {
      auth        = local.contabo_auth_from_module[acct_key]
      labels      = try(module.contabo_account_state[acct_key].nodes.labels, {})
      annotations = try(module.contabo_account_state[acct_key].nodes.annotations, {})
      nodes       = local.contabo_nodes_from_module[acct_key]
    }
  }

  contabo_nodes = length(local.contabo_accounts_effective) > 0 ? merge([
    for account_key, account in local.contabo_accounts_effective : {
      for node_key, node in account.nodes : node_key => {
        account_key = account_key
        account     = account
        node_key    = node_key
        node        = node
      }
    }
  ]...) : {}
}
```

Note: `local.contabo_account_keys` now comes from a different source. Redefine it:
```hcl
  # Source of truth: the inventory/ tree in R2, enumerated via a thin
  # manifest file committed to the repo that lists which accounts exist.
  # (See tofu/shared/accounts.yaml created in Task 15.)
  contabo_account_keys = keys(local.accounts_manifest.contabo)
  # local.accounts_manifest is declared in Task 15.
```

- [ ] **Step 2: Update `nodes.tf` — the module inputs no longer reference `var.contabo_accounts`**

The existing block:
```hcl
  contabo_client_id     = each.value.account.auth.oauth2_client_id
  contabo_client_secret = each.value.account.auth.oauth2_client_secret
  contabo_api_user      = each.value.account.auth.oauth2_user
  contabo_api_password  = each.value.account.auth.oauth2_pass
```
continues to work because `each.value.account` now resolves via `contabo_accounts_effective` (which pulls from the module). No text change needed once Task 15's manifest exists.

- [ ] **Step 3: Delete `variable "contabo_accounts"` from `variables.tf`**

Remove the block wholesale.

- [ ] **Step 4: Update the `contabo` provider alias**

In `main.tf`, the existing `provider "contabo"` for_each block that reads `auth.oauth2_*` needs to reference the new effective map — which it already does via `contabo_accounts_effective`. No text change needed.

- [ ] **Step 5: Validate**

```bash
# cwd: tofu/layers/01-contabo-infra
tofu validate
```
Expected: `Success!` (the accounts manifest from Task 14 is in place; `local.accounts_manifest` resolves cleanly).

- [ ] **Step 6: Commit**

```bash
git add tofu/layers/01-contabo-infra/main.tf tofu/layers/01-contabo-infra/variables.tf
git commit -m "Source Contabo auth and nodes from R2"
```

---

## Phase 2 — Wire layer 02 (Oracle + on-prem)

### Task 16: Source Oracle auth/nodes/state from R2

**Files:**
- Modify: `tofu/layers/02-oracle-infra/main.tf`
- Modify: `tofu/layers/02-oracle-infra/variables.tf`
- Create: `tofu/layers/02-oracle-infra/state-writer.tf`

- [ ] **Step 1: Add the node-state module instantiations**

Append to `tofu/layers/02-oracle-infra/main.tf`:
```hcl
module "oracle_account_state" {
  for_each      = toset(local.accounts_manifest.oracle)
  source        = "../../modules/node-state"
  provider_name = "oracle"
  account       = each.key
  age_recipients = split(",", var.age_recipients)
}

locals {
  oracle_account_keys = local.accounts_manifest.oracle
  oracle_auth_from_module = {
    for k, mod in module.oracle_account_state : k => try(mod.auth.auth, null)
  }
  oracle_nodes_from_module = {
    for k, mod in module.oracle_account_state : k => try(mod.nodes.nodes, {})
  }
  oracle_state_from_module = {
    for k, mod in module.oracle_account_state : k => try(mod.state.nodes, {})
  }

  oci_accounts_effective = {
    for k in local.oracle_account_keys : k => merge(
      try(local.oracle_auth_from_module[k], {}),
      { nodes = local.oracle_nodes_from_module[k] }
    )
  }
}
```

- [ ] **Step 2: Update the `oci` provider block**

Existing:
```hcl
provider "oci" {
  for_each            = local.oci_provider_accounts
  ...
  tenancy_ocid        = each.value.tenancy_ocid
  region              = each.value.region
  config_file_profile = each.key
  auth                = "SecurityToken"
}
```
Replace with a version that reads from the module:
```hcl
provider "oci" {
  for_each            = local.oci_provider_accounts
  alias               = "account"
  tenancy_ocid        = local.oracle_auth_from_module[each.key].tenancy_ocid
  region              = local.oracle_auth_from_module[each.key].region
  config_file_profile = local.oracle_auth_from_module[each.key].config_file_profile
  auth                = local.oracle_auth_from_module[each.key].auth_method
}
```
Update `local.oci_provider_accounts`:
```hcl
locals {
  oci_provider_accounts = toset(local.oracle_account_keys)
}
```

- [ ] **Step 3: Update the `module "oracle_account"` block to source from effective map**

```hcl
module "oracle_account" {
  for_each  = local.oci_accounts_effective
  source    = "../../modules/oracle-account-infra"
  providers = { oci = oci.account[each.key] }

  account_key                          = each.key
  compartment_ocid                     = each.value.compartment_ocid
  region                               = each.value.region
  vcn_cidr                             = each.value.vcn_cidr
  enable_ipv6                          = try(each.value.enable_ipv6, true)
  nodes                                = each.value.nodes
  labels                               = try(each.value.labels, {})
  annotations                          = try(each.value.annotations, {})
  bastion_client_cidr_block_allow_list = try(each.value.bastion_client_cidr_block_allow_list, ["0.0.0.0/0"])
  cluster_name                         = var.cluster_name
  cluster_endpoint                     = var.cluster_endpoint
  talos_version                        = var.talos_version
  force_image_generation               = var.force_image_generation
  kubernetes_version                   = var.kubernetes_version
  machine_secrets                      = data.terraform_remote_state.secrets.outputs.machine_secrets
  shared_patches_dir                   = "${path.module}/../../shared/patches"
}
```

- [ ] **Step 4: Delete `variable "oci_accounts"` and `variable "retained_oci_accounts"`**

Remove both blocks from `variables.tf`. Add:
```hcl
variable "age_recipients" { type = string }
```

- [ ] **Step 5: Write the state writer**

File: `tofu/layers/02-oracle-infra/state-writer.tf`
```hcl
module "oracle_account_state_writer" {
  for_each      = toset(local.oracle_account_keys)
  source        = "../../modules/node-state"
  provider_name = "oracle"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_state = true
  state_content = {
    provider = "oracle"
    account  = each.key
    nodes = try({
      for node_key, node in module.oracle_account[each.key].nodes :
        node_key => {
          provider_data = {
            oci_instance_ocid = node.id
            shape             = node.shape
            ocpus             = node.ocpus
            memory_gb         = node.memory_gb
            region            = node.region
            ipv4              = node.ipv4
            ipv6              = node.ipv6
            status            = "running"
            discovered_at     = timestamp()
          }
        }
    }, {})
  }

  depends_on = [module.oracle_account]
}
```

- [ ] **Step 6: Ensure `modules/oracle-account-infra` exposes a `nodes` output**

Open `tofu/modules/oracle-account-infra/outputs.tf` and add:
```hcl
output "nodes" {
  value = {
    for k, n in module.node : k => {
      id        = n.id
      shape     = n.shape
      ocpus     = n.ocpus
      memory_gb = n.memory_gb
      region    = var.region
      ipv4      = n.ipv4
      ipv6      = n.ipv6
    }
  }
}
```
Ensure the underlying `node-oracle` module exposes those attributes in its own `outputs.tf` as well; add any that are missing.

- [ ] **Step 7: Validate**

```bash
# cwd: tofu/layers/02-oracle-infra
tofu init -backend=false -upgrade >/dev/null && tofu validate
```
Expected: `Success!`.

- [ ] **Step 8: Commit**

```bash
git add tofu/layers/02-oracle-infra/*.tf tofu/modules/oracle-account-infra/outputs.tf tofu/modules/node-oracle/outputs.tf
git commit -m "Source Oracle inventory from R2; add state.yaml writer"
```

---

### Task 17: Dynamic import for Oracle (mirrors Task 12)

**Files:**
- Create: `tofu/layers/02-oracle-infra/imports.tf`

- [ ] **Step 1: Write the import block**

File: `tofu/layers/02-oracle-infra/imports.tf`
```hcl
locals {
  oracle_existing_instance_ocids = merge([
    for acct_key, node_map in local.oracle_state_from_module : {
      for node_key, node in node_map :
        "${acct_key}-${node_key}" => try(node.provider_data.oci_instance_ocid, null)
        if try(node.provider_data.oci_instance_ocid, null) != null
    }
  ]...)
}

import {
  for_each = local.oracle_existing_instance_ocids
  to       = module.oracle_account[split("-", each.key, 2)[0]].module.node[split("-", each.key, 2)[1]].oci_core_instance.this
  id       = each.value
}
```

(If `module.oracle_account_infra`'s internal structure uses a different path, update the `to = ...` line. Verify with `tofu graph` or by inspecting `tofu/modules/oracle-account-infra/nodes.tf`.)

- [ ] **Step 2: Validate**

```bash
# cwd: tofu/layers/02-oracle-infra
tofu validate
```
Expected: `Success!`.

- [ ] **Step 3: Commit**

```bash
git add tofu/layers/02-oracle-infra/imports.tf
git commit -m "Drive Oracle imports from state.yaml"
```

---

### Task 18: On-prem reads nodes.yaml from R2

**Files:**
- Modify: `tofu/layers/02-onprem-infra/main.tf`
- Modify: `tofu/layers/02-onprem-infra/variables.tf`
- Create: `tofu/layers/02-onprem-infra/state-writer.tf`

- [ ] **Step 1: Replace the `onprem_accounts` var consumer with module reads**

Rewrite `main.tf` (preserve existing account/node flattening logic, but source from the module):
```hcl
module "onprem_account_state" {
  for_each      = toset(local.accounts_manifest.onprem)
  source        = "../../modules/node-state"
  provider_name = "onprem"
  account       = each.key
  age_recipients = split(",", var.age_recipients)
}

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))

  onprem_account_keys = local.accounts_manifest.onprem
  onprem_nodes_from_module = {
    for k, mod in module.onprem_account_state : k => try(mod.nodes.nodes, {})
  }

  onprem_accounts_effective = {
    for k in local.onprem_account_keys : k => {
      nodes = local.onprem_nodes_from_module[k]
    }
  }

  flattened_nodes = merge([
    for acct_key, acct in local.onprem_accounts_effective : {
      for node_key, node in acct.nodes : "${acct_key}-${node_key}" => {
        account_key = acct_key
        node_key    = node_key
        node        = node
      }
    }
  ]...)
}
```

- [ ] **Step 2: Delete `variable "onprem_accounts"` and add `age_recipients`**

`variables.tf`:
```hcl
variable "age_recipients" { type = string }
# remove variable "onprem_accounts"
```

- [ ] **Step 3: Write the state writer (on-prem state is mostly metadata)**

File: `tofu/layers/02-onprem-infra/state-writer.tf`
```hcl
module "onprem_account_state_writer" {
  for_each      = toset(local.onprem_account_keys)
  source        = "../../modules/node-state"
  provider_name = "onprem"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_state = true
  state_content = {
    provider = "onprem"
    account  = each.key
    nodes = {
      for node_key, node in local.onprem_nodes_from_module[each.key] :
        node_key => {
          provider_data = {
            role          = node.role
            region        = try(node.region, null)
            discovered_at = timestamp()
          }
        }
    }
  }
}
```

- [ ] **Step 4: Validate**

```bash
# cwd: tofu/layers/02-onprem-infra
tofu init -backend=false -upgrade >/dev/null && tofu validate
```
Expected: `Success!`.

- [ ] **Step 5: Commit**

```bash
git add tofu/layers/02-onprem-infra/*.tf
git commit -m "Source on-prem inventory from R2; add state.yaml writer"
```

---

## Phase 3 — Wire layer 03 (Talos render + upgrade)

### Task 19: Layer 03 reads upstream state from R2 via node-state

**Files:**
- Modify: `tofu/layers/03-talos/main.tf`

- [ ] **Step 1: Add per-provider node-state module reads**

Append to `tofu/layers/03-talos/main.tf`:
```hcl
module "contabo_state" {
  for_each      = toset(local.accounts_manifest.contabo)
  source        = "../../modules/node-state"
  provider_name = "contabo"
  account       = each.key
  age_recipients = split(",", var.age_recipients)
}

module "oracle_state" {
  for_each      = toset(local.accounts_manifest.oracle)
  source        = "../../modules/node-state"
  provider_name = "oracle"
  account       = each.key
  age_recipients = split(",", var.age_recipients)
}

module "onprem_state" {
  for_each      = toset(local.accounts_manifest.onprem)
  source        = "../../modules/node-state"
  provider_name = "onprem"
  account       = each.key
  age_recipients = split(",", var.age_recipients)
}

locals {
  # All nodes regardless of provider, keyed by node_key.
  # Each value carries provider, account, role, labels, annotations, and
  # address info sufficient for rendering and applying Talos config.
  all_nodes_from_state = merge(
    flatten([
      for acct_key, mod in module.contabo_state : [
        for node_key, node in try(mod.state.nodes, {}) : {
          (node_key) = merge(
            { provider = "contabo", account = acct_key },
            try(mod.nodes.nodes[node_key], {}),
            node.provider_data,
          )
        }
      ]
    ])...,
    flatten([
      for acct_key, mod in module.oracle_state : [
        for node_key, node in try(mod.state.nodes, {}) : {
          ("${acct_key}-${node_key}") = merge(
            { provider = "oracle", account = acct_key },
            try(mod.nodes.nodes[node_key], {}),
            node.provider_data,
          )
        }
      ]
    ])...,
    flatten([
      for acct_key, mod in module.onprem_state : [
        for node_key, node in try(mod.state.nodes, {}) : {
          ("${acct_key}-${node_key}") = merge(
            { provider = "onprem", account = acct_key },
            try(mod.nodes.nodes[node_key], {}),
            node.provider_data,
          )
        }
      ]
    ])...,
  )

  # Flat map of upstream talos state across providers, keyed by node_key
  # (same key used in all_nodes_from_state).
  upstream_talos_state = merge(
    { for acct_key, mod in module.contabo_state :
        acct_key => try(mod.talos_state.nodes, {}) },
    { for acct_key, mod in module.oracle_state :
        acct_key => try(mod.talos_state.nodes, {}) },
    { for acct_key, mod in module.onprem_state :
        acct_key => try(mod.talos_state.nodes, {}) },
  )
}
```

- [ ] **Step 2: Add the `age_recipients` variable**

`variables.tf`:
```hcl
variable "age_recipients" { type = string }
```

- [ ] **Step 3: Validate**

```bash
# cwd: tofu/layers/03-talos
tofu init -backend=false -upgrade >/dev/null && tofu validate
```
Expected: `Success!`.

- [ ] **Step 4: Commit**

```bash
git add tofu/layers/03-talos/main.tf tofu/layers/03-talos/variables.tf
git commit -m "Layer 03 reads upstream state from R2 via node-state modules"
```

---

### Task 20: Render into `machine-configs.yaml` (Layer 03)

**Files:**
- Modify: `tofu/layers/03-talos/configs.tf`
- Create: `tofu/layers/03-talos/machine-configs-writer.tf`

- [ ] **Step 1: Replace the existing `local.controlplane_nodes` / `local.worker_nodes` derivations**

In `tofu/layers/03-talos/configs.tf`, near the top, replace any derivation that reads from `terraform_remote_state.contabo` / `.oracle` etc. for node metadata with:
```hcl
locals {
  controlplane_nodes = {
    for k, v in local.all_nodes_from_state : k => v if v.role == "controlplane"
  }
  worker_nodes = {
    for k, v in local.all_nodes_from_state : k => v if v.role == "worker"
  }
}
```

Keep the existing `data "talos_machine_configuration"` resources unchanged; they read `for_each = local.controlplane_nodes` etc.

- [ ] **Step 2: Write the machine-configs writer**

File: `tofu/layers/03-talos/machine-configs-writer.tf`
```hcl
# Per-account machine-configs.yaml writer. Encrypts + uploads to R2.

locals {
  # Nodes grouped by (provider, account) for one file per account.
  nodes_by_account = {
    for k, v in local.all_nodes_from_state :
      "${v.provider}/${v.account}" => {
        provider = v.provider
        account  = v.account
        # Accumulate node configs under this group.
      }...
  }
}

module "contabo_machine_configs_writer" {
  for_each      = toset(local.accounts_manifest.contabo)
  source        = "../../modules/node-state"
  provider_name = "contabo"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_machine_configs = true
  machine_configs_content = {
    provider = "contabo"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
        node_key => {
          target_talos_version  = var.talos_version
          schematic_id          = talos_image_factory_schematic.this.id
          rendered_at           = timestamp()
          rendered_by_run_id    = var.ci_run_id
          machine_type          = node.role
          machine_configuration = try(
            data.talos_machine_configuration.cp[node_key].machine_configuration,
            data.talos_machine_configuration.worker[node_key].machine_configuration,
          )
        }
        if node.provider == "contabo" && node.account == each.key
    }
  }
}

module "oracle_machine_configs_writer" {
  for_each      = toset(local.accounts_manifest.oracle)
  source        = "../../modules/node-state"
  provider_name = "oracle"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_machine_configs = true
  machine_configs_content = {
    provider = "oracle"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
        node_key => {
          target_talos_version  = var.talos_version
          schematic_id          = talos_image_factory_schematic.this.id
          rendered_at           = timestamp()
          rendered_by_run_id    = var.ci_run_id
          machine_type          = node.role
          machine_configuration = data.talos_machine_configuration.worker[node_key].machine_configuration
        }
        if node.provider == "oracle" && node.account == each.key
    }
  }
}

module "onprem_machine_configs_writer" {
  for_each      = toset(local.accounts_manifest.onprem)
  source        = "../../modules/node-state"
  provider_name = "onprem"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_machine_configs = true
  machine_configs_content = {
    provider = "onprem"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
        node_key => {
          target_talos_version  = var.talos_version
          schematic_id          = talos_image_factory_schematic.this.id
          rendered_at           = timestamp()
          rendered_by_run_id    = var.ci_run_id
          machine_type          = node.role
          machine_configuration = data.talos_machine_configuration.worker[node_key].machine_configuration
        }
        if node.provider == "onprem" && node.account == each.key
    }
  }
}
```

Add `ci_run_id` variable to `variables.tf`:
```hcl
variable "ci_run_id" {
  type        = string
  default     = "local"
  description = "Set by CI to $GITHUB_RUN_ID; used only for audit metadata in machine-configs.yaml."
}
```

- [ ] **Step 3: Validate**

```bash
# cwd: tofu/layers/03-talos
tofu validate
```
Expected: `Success!`.

- [ ] **Step 4: Commit**

```bash
git add tofu/layers/03-talos/*.tf
git commit -m "Layer 03 renders machine-configs.yaml per provider/account"
```

---

### Task 21: Add upgrade detection + `null_resource.talos_upgrade`

**Files:**
- Create: `tofu/layers/03-talos/upgrade.tf`
- Create: `tofu/layers/03-talos/talos-state-writer.tf`

- [ ] **Step 1: Write the upgrade resource**

File: `tofu/layers/03-talos/upgrade.tf`
```hcl
locals {
  # Nodes whose last-applied Talos version differs from target.
  # Excludes nodes with no recorded last_applied (first-apply path).
  upgrade_needed = {
    for k, v in local.all_nodes_from_state : k => v
    if try(local.upstream_talos_state_by_node[k].last_applied_version, "") != "" &&
       local.upstream_talos_state_by_node[k].last_applied_version != var.talos_version
  }

  upstream_talos_state_by_node = merge([
    for acct_key, node_map in local.upstream_talos_state : node_map
  ]...)
}

resource "null_resource" "talos_upgrade" {
  for_each = local.upgrade_needed

  triggers = {
    from_version = local.upstream_talos_state_by_node[each.key].last_applied_version
    to_version   = var.talos_version
    schematic_id = talos_image_factory_schematic.this.id
    node_ipv4    = each.value.ipv4
  }

  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      NODE           = each.value.ipv4
      TALOSCONFIG    = local_sensitive_file.talosconfig.filename
      IMAGE          = data.talos_image_factory_urls.this.urls.installer
      EXPECT_VERSION = var.talos_version
    }
    command = "${path.root}/../../scripts/talos-upgrade.sh"
  }
}
```

Ensure `local_sensitive_file.talosconfig` exists somewhere in layer 03 (check `apply.tf` — if it's not there, add it, reading from the existing `data.terraform_remote_state.secrets.outputs.talos_config`).

- [ ] **Step 2: Make `talos_machine_configuration_apply` depend on the upgrade**

Edit `apply.tf` in the `talos_machine_configuration_apply` resource — add:
```hcl
  depends_on = [null_resource.talos_upgrade]
```

- [ ] **Step 3: Write the talos-state writer**

File: `tofu/layers/03-talos/talos-state-writer.tf`
```hcl
# Writes talos-state.yaml per provider/account with the last-applied version
# and config hash. Depends on the apply succeeding so we never record a
# version that didn't actually land.

locals {
  # Hash of the rendered machine_configuration per node.
  config_hash_by_node = {
    for k, node in local.all_nodes_from_state :
      k => sha256(try(
        data.talos_machine_configuration.cp[k].machine_configuration,
        data.talos_machine_configuration.worker[k].machine_configuration,
      ))
  }
}

module "contabo_talos_state_writer" {
  for_each      = toset(local.accounts_manifest.contabo)
  source        = "../../modules/node-state"
  provider_name = "contabo"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_talos_state = true
  talos_state_content = {
    provider = "contabo"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
        node_key => {
          last_applied_version = var.talos_version
          last_applied_at      = timestamp()
          last_applied_run_id  = var.ci_run_id
          config_hash          = local.config_hash_by_node[node_key]
        }
        if node.provider == "contabo" && node.account == each.key
    }
  }

  depends_on = [talos_machine_configuration_apply.this]
}

module "oracle_talos_state_writer" {
  for_each      = toset(local.accounts_manifest.oracle)
  source        = "../../modules/node-state"
  provider_name = "oracle"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_talos_state = true
  talos_state_content = {
    provider = "oracle"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
        node_key => {
          last_applied_version = var.talos_version
          last_applied_at      = timestamp()
          last_applied_run_id  = var.ci_run_id
          config_hash          = local.config_hash_by_node[node_key]
        }
        if node.provider == "oracle" && node.account == each.key
    }
  }

  depends_on = [talos_machine_configuration_apply.this]
}

module "onprem_talos_state_writer" {
  for_each      = toset(local.accounts_manifest.onprem)
  source        = "../../modules/node-state"
  provider_name = "onprem"
  account       = each.key
  age_recipients = split(",", var.age_recipients)

  write_talos_state = true
  talos_state_content = {
    provider = "onprem"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
        node_key => {
          last_applied_version = var.talos_version
          last_applied_at      = timestamp()
          last_applied_run_id  = var.ci_run_id
          config_hash          = local.config_hash_by_node[node_key]
        }
        if node.provider == "onprem" && node.account == each.key
    }
  }

  depends_on = [talos_machine_configuration_apply.this]
}
```

- [ ] **Step 4: Validate**

```bash
# cwd: tofu/layers/03-talos
tofu validate
```
Expected: `Success!`.

- [ ] **Step 5: Commit**

```bash
git add tofu/layers/03-talos/upgrade.tf tofu/layers/03-talos/talos-state-writer.tf tofu/layers/03-talos/apply.tf
git commit -m "Layer 03: in-place Talos upgrade + talos-state.yaml writer"
```

---

## Phase 4 — Workflow + cleanup

### Task 22: Update the GitHub Actions workflow

**Files:**
- Modify: `.github/workflows/tofu-layer.yml`
- Modify: `.github/workflows/tofu-apply.yml`

- [ ] **Step 1: Remove the `TF_VAR_contabo_accounts` env write**

In `.github/workflows/tofu-layer.yml`, delete the entire "Configure Contabo inventory" step:
```yaml
      - name: Configure Contabo inventory
        if: inputs.layer == '01-contabo-infra'
        run: |
          ...
          echo "TF_VAR_contabo_accounts=$(cat /tmp/contabo_accounts.json)" >> "$GITHUB_ENV"
```

Delete the Oracle / on-prem equivalents that write `TF_VAR_oci_accounts` / `TF_VAR_retained_oci_accounts` / `TF_VAR_onprem_accounts` to `$GITHUB_ENV`.

- [ ] **Step 2: Add a conditional seed step**

Before the `Init` step add:
```yaml
      - name: Seed R2 inventory (one-time bootstrap)
        if: inputs.layer == '01-contabo-infra' || inputs.layer == '02-oracle-infra' || inputs.layer == '02-onprem-infra'
        env:
          AWS_ACCESS_KEY_ID:     ${{ secrets.R2_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          R2_ENDPOINT_URL:       https://${{ secrets.R2_ACCOUNT_ID }}.r2.cloudflarestorage.com
          AWS_EC2_METADATA_DISABLED: "true"
          CONTABO_CLIENT_ID:     ${{ secrets.CONTABO_CLIENT_ID }}
          CONTABO_CLIENT_SECRET: ${{ secrets.CONTABO_CLIENT_SECRET }}
          CONTABO_API_USER:      ${{ secrets.CONTABO_API_USER }}
          CONTABO_API_PASSWORD:  ${{ secrets.CONTABO_API_PASSWORD }}
          SOPS_AGE_KEY:          ${{ secrets.SOPS_AGE_KEY }}
          SOPS_AGE_RECIPIENTS:   ${{ vars.SOPS_AGE_RECIPIENTS }}
        run: |
          set -euo pipefail
          if aws s3 ls "s3://cluster-tofu-state/production/inventory/" \
               --endpoint-url "$R2_ENDPOINT_URL" --region us-east-1 \
             | grep -q .; then
            echo "::notice::inventory/ already present — skipping seed"
            exit 0
          fi
          # Install deps
          pip3 install --user pyyaml
          # Iterate accounts.yaml; for each provider, run seed
          python3 - <<'PY'
          import subprocess, yaml
          manifest = yaml.safe_load(open("tofu/shared/accounts.yaml"))
          for acct in manifest.get("contabo", []):
              subprocess.check_call([
                  "scripts/seed-inventory.sh",
                  "--contabo-account", acct,
                  "--bootstrap", "tofu/shared/bootstrap/contabo-instance-ids.yaml",
                  "--contabo-list-cmd", "scripts/contabo-list-instances.sh",
              ])
          for acct in manifest.get("oracle", []):
              subprocess.check_call([
                  "scripts/seed-inventory.sh",
                  "--oci-account", acct,
                  "--oci-list-cmd", "scripts/oci-list-instances.sh",
              ])
          PY
```

Add `scripts/contabo-list-instances.sh` and `scripts/oci-list-instances.sh` as thin shell wrappers around `curl`/`oci-cli` that print the JSON the seed script expects. Minimal content:

File: `scripts/contabo-list-instances.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
TOKEN=$(curl -sS -XPOST \
  -d "grant_type=password&client_id=$CONTABO_CLIENT_ID&client_secret=$CONTABO_CLIENT_SECRET&username=$CONTABO_API_USER&password=$CONTABO_API_PASSWORD" \
  https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token | jq -r .access_token)
curl -sS -H "Authorization: Bearer $TOKEN" \
  -H "x-request-id: $(uuidgen)" \
  "https://api.contabo.com/v1/compute/instances?size=100"
```

File: `scripts/oci-list-instances.sh`
```bash
#!/usr/bin/env bash
set -euo pipefail
: "${OCI_COMPARTMENT_OCID:?}"
oci compute instance list --compartment-id "$OCI_COMPARTMENT_OCID" --all --auth security_token
```

Make them executable.

- [ ] **Step 3: Wire `TF_VAR_age_recipients` into the Plan and Apply steps**

In the same workflow's Plan and Apply env lists, add:
```yaml
          TF_VAR_age_recipients: ${{ vars.SOPS_AGE_RECIPIENTS }}
```

- [ ] **Step 4: Drop the "Fetch cluster config from R2" and "Render canonical inventory" steps**

Delete both steps in their entirety — the inventory now lives under `production/inventory/` and is read by the layers themselves.

- [ ] **Step 5: Lint the workflow file**

```bash
actionlint .github/workflows/tofu-layer.yml
```
Expected: no errors.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/tofu-layer.yml .github/workflows/tofu-apply.yml \
        scripts/contabo-list-instances.sh scripts/oci-list-instances.sh
git commit -m "Workflow: add R2 inventory seed step; drop TF_VAR_*_accounts env wiring"
```

---

### Task 23: Add the zero-diff regression check to `tofu-plan.yml`

**Files:**
- Create: `.github/workflows/tofu-plan-regression.yml`

- [ ] **Step 1: Write the regression workflow**

File: `.github/workflows/tofu-plan-regression.yml`
```yaml
# Catches layers that propose unexpected changes on a steady-state plan.
# Runs after every tofu-plan on main/PR; fails if any layer has a non-zero
# resource diff.
name: tofu-plan-regression
on:
  workflow_run:
    workflows: [tofu-plan]
    types: [completed]
  workflow_dispatch:

jobs:
  check:
    runs-on: ubuntu-latest
    if: ${{ github.event.workflow_run.conclusion == 'success' || github.event_name == 'workflow_dispatch' }}
    strategy:
      fail-fast: false
      matrix:
        layer: [01-contabo-infra, 02-oracle-infra, 02-onprem-infra, 03-talos]
    steps:
      - uses: actions/checkout@v5
      - uses: actions/download-artifact@v4
        with:
          pattern: tfplan-${{ matrix.layer }}
          run-id: ${{ github.event.workflow_run.id }}
          github-token: ${{ secrets.GITHUB_TOKEN }}
      - name: Assert zero resource diffs
        run: |
          tofu show -json "tfplan-${{ matrix.layer }}/tfplan" > plan.json
          n=$(jq '[.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length' plan.json)
          echo "::notice::layer=${{ matrix.layer }} non-noop-diffs=$n"
          if [ "$n" -ne 0 ]; then
            jq '.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | {address,actions:.change.actions}' plan.json
            echo "::error::layer ${{ matrix.layer }} proposes $n changes on a steady-state plan"
            exit 1
          fi
```

- [ ] **Step 2: Lint**

```bash
actionlint .github/workflows/tofu-plan-regression.yml
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/tofu-plan-regression.yml
git commit -m "Add zero-diff regression check on every tofu-plan"
```

---

### Task 24: Clean up the now-dead paths

**Files:**
- Delete: `tofu/layers/01-contabo-infra/imports.tf` **NO — we rewrote it in Task 12, keep it.**
  (Double-check: after Task 12 the file exists and is dynamic. No deletion.)
- Modify: `scripts/render-cluster-config.py`
- Delete: `tofu/shared/bootstrap/contabo-instance-ids.yaml` **only after the first successful apply in production writes `state.yaml`**

- [ ] **Step 1: Slim `scripts/render-cluster-config.py`**

Open the file. Remove every codepath producing `*_accounts.json` (contabo/oci/onprem). Preserve any code that renders or validates nodes.yaml shapes if useful to seed-inventory.sh. If the script has no remaining purpose, delete it:

```bash
git rm scripts/render-cluster-config.py
```

- [ ] **Step 2: Post-first-apply bootstrap cleanup (manual, after production apply succeeds)**

Once the production `tofu-apply` completes successfully and `state.yaml` is present in R2 for every account, the operator runs:
```bash
git rm tofu/shared/bootstrap/contabo-instance-ids.yaml
git commit -m "Retire one-time Contabo instance-ID bootstrap fallback"
```

**Do NOT execute this step in CI.** It's a one-shot human commit after confirming R2 has the real data.

- [ ] **Step 3: Commit the script cleanup**

```bash
git add scripts/render-cluster-config.py || true
git commit -m "Retire render-cluster-config.py — inventory is now sourced from R2"
```

---

## Phase 5 — Steady-state verification

### Task 25: Run the full plan against production R2 and confirm zero diffs

**No code changes — verification only.**

- [ ] **Step 1: From a worktree, authenticate as the CI identity (or operator with the same R2 + age credentials) and run a local plan against each layer**

```bash
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... R2_ACCOUNT_ID=...
export TF_VAR_r2_account_id=$R2_ACCOUNT_ID
export TF_VAR_age_recipients="age1..."
export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt

for layer in 00-talos-secrets 01-contabo-infra 02-oracle-infra 02-onprem-infra 03-talos; do
  ( cd "tofu/layers/$layer" \
    && tofu init -backend-config="endpoints={s3=\"https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com\"}" \
    && tofu plan -out=tfplan -lock=false \
    && tofu show -json tfplan | jq '[.resource_changes[] | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length' \
  ) || exit 1
done
```
Expected: the count is `0` for every layer (the steady-state invariant).

- [ ] **Step 2: If any layer shows a non-zero diff, capture and resolve**

```bash
( cd "tofu/layers/<offending>" && tofu show tfplan )
```
Investigate; fix inline.

- [ ] **Step 3: Trigger the GitHub `tofu-apply` workflow against main**

Via `gh workflow run tofu-apply.yml`. Watch for: (a) seed step skips (inventory already there), (b) all layers green, (c) no credential dumps in logs, (d) no resource diffs.

- [ ] **Step 4: Trigger a Talos version bump drill**

Update `tofu/shared/versions.auto.tfvars`:
```hcl
talos_version = "v1.12.7"  # current is v1.12.6
```
Push, open a PR, confirm plan shows `null_resource.talos_upgrade` in `+ create` for every node. Do NOT merge the drill PR unless you actually intend to upgrade.

- [ ] **Step 5: If all steps pass, mark the plan complete**

No commit for this task — it's a verification gate only.

---

## Self-review notes (author)

**Spec coverage:**
- Problem §1 (import target error) → Tasks 7, 11, 12, 22 (replaces hardcoded IDs with dynamic ones).
- Problem §2 (credential leak) → Tasks 14, 22 (removes TF_VAR_contabo_accounts aggregation).
- Problem §3 (no Talos upgrade) → Tasks 8, 19, 21 (talos-upgrade.sh + upgrade resource + version diff).
- Goals: idempotent → Task 23 regression check.
- R2 inventory layout → Tasks 4–6, 11, 16, 18, 19, 20, 21.
- File schemas → Task 9 renderer + all writer content blocks.
- `node-state` module → Tasks 4, 5, 6.
- `seed-inventory.sh` / `talos-upgrade.sh` → Tasks 8, 10.
- SOPS validation → Tasks 2, 3.
- Credential flow (post-refactor) → Tasks 14, 22.
- Bootstrap / migration → Tasks 7, 15, 22, 24.
- Error handling table → realised by writer preconditions (Task 6), `check` block (Task 3), fallback handling in seed script (Task 10).
- Testing plan → Tasks 8, 9, 10 (unit); Task 25 (integration); Task 23 (regression CI).
- Open questions — none; both deferred decisions are baked in.

**Placeholder scan:** searched for TBD/TODO/"fill in"/"appropriate error handling" — none remain.

**Type consistency:** `provider_name` (module input) vs `provider` (YAML field) is intentional; `provider` stays a reserved word in tofu but is a normal key in YAML. `talos_state` (snake_case in module outputs) aligns with `talos-state.yaml` filename convention. Node key shapes:
- Contabo / on-prem: node_key directly.
- Oracle: `${account}-${node_key}` (because Oracle node keys can collide across accounts by design).
- Layer 03 uses the composite keys for Oracle throughout.

**Executable check** (sanity): every code step either shows full file contents, or gives an exact substring-replace target inside a named file. No "edit around line 42" without showing the new content.
