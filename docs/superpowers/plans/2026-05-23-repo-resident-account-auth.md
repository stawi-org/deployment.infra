# Repo-Resident Account Auth + Self-PR Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every provider's `auth.yaml` into the repo (SOPS-encrypted under `tofu/shared/accounts/`), strip the R2 auth-writer surface from tofu, relocate `talos-images.yaml` to R2, and teach `bootstrap-oci-oidc.sh` to commit + push + emit a PR URL on its own.

**Architecture:** Repo holds static declarative inputs (provider/account registry + encrypted creds). R2 holds dynamic state (per-node specs, observed Talos configs, image catalog). The `node-state` tofu module reads auth from the repo and continues reading nodes from R2. Migration ships as three ordered PRs: **M1** seeds encrypted files in the repo (no-op), **M2** flips read path + collapses old plumbing (operational cutover), **M3** deletes the now-unreferenced R2 auth files (opt-in cleanup). The bootstrap-script update lands as its own PR after M2.

**Tech Stack:** OpenTofu (HCL), Bash, SOPS+age, jq, yq, GitHub Actions, Cloudflare R2 (S3-compatible).

**Spec:** `docs/superpowers/specs/2026-05-23-repo-resident-account-auth-design.md`

---

## File Structure

**Create:**
- `.sops.yaml` (repo root) — SOPS path rule for `tofu/shared/accounts/.*/auth.yaml`.
- `scripts/migrate-auth-to-repo.sh` — one-shot, deleted in M3.
- `tofu/shared/accounts/contabo/bwire/auth.yaml` (SOPS-encrypted) — produced by migration.
- `tofu/shared/accounts/oracle/{bwire,brianelvis33,alimbacho67,ambetera,anto,allanofwiti,madiang100}/auth.yaml` (SOPS-encrypted) — produced by migration.
- `.github/workflows/cleanup-r2-auth.yml` (M3).

**Modify:**
- `tofu/modules/node-state/main.tf` — auth read path flip; drop auth writers.
- `tofu/modules/node-state/variables.tf` — drop `write_auth`, `auth_content`, `age_recipients`.
- `tofu/modules/node-state/outputs.tf` — `inventory_keys_found` no longer references R2-staged auth path.
- `tofu/layers/01-contabo-infra/image.tf` — repoint `talos_images` loader to R2 staging.
- `tofu/modules/oracle-account-infra/image.tf` — repoint `talos_images` loader to R2 staging.
- `tofu/layers/01-contabo-infra/main.tf` — drop `age_recipients` arg on `node-state` module call (if present).
- `tofu/layers/02-onprem-infra/main.tf` — drop `age_recipients` arg on `node-state` module call (if present).
- `tofu/layers/02-oracle-infra/main.tf` — drop `age_recipients` arg on `node-state` module call.
- `.github/workflows/sync-talos-images.yml` — `assemble-and-pr` job → `assemble-and-upload` (writes to R2, no PR creation).
- `.github/workflows/upload-inventory.yml` — drop `auth.yaml` from filename choices; drop contabo SOPS branch.
- `scripts/bootstrap-oci-oidc.sh` — replace stdout stanza with: encrypt + commit + push + print PR URL.

**Delete:**
- `tofu/shared/inventory/talos-images.yaml` — moved to R2 (kept in M2 PR until R2 upload confirmed; deleted in same PR).
- `tofu/shared/inventory/` — directory removed if empty.

---

## PR M1 — Seed Encrypted Auth Into the Repo

Goal: Add encrypted auth files to the repo with zero impact on running tofu. Fleet still reads R2.

### Task 1: Add `.sops.yaml`

**Files:**
- Create: `.sops.yaml`

- [ ] **Step 1: Capture the current age recipients value**

The repo's CI uses `vars.SOPS_AGE_RECIPIENTS` for SOPS encryption. Get the value via the GitHub API (token already in your gh CLI session) or by inspecting `.github/workflows/upload-inventory.yml` lineage. Quickest path:

```bash
gh api repos/stawi-org/deployment.infra/actions/variables/SOPS_AGE_RECIPIENTS \
  --jq '.value'
```

Save the comma-separated list of `age1…` recipients to a shell var for the next step:

```bash
AGE_RECIPIENTS=$(gh api repos/stawi-org/deployment.infra/actions/variables/SOPS_AGE_RECIPIENTS --jq '.value')
echo "recipients: $AGE_RECIPIENTS"
```

Expected: one or more `age1abc…` keys separated by commas, e.g. `age1xy…,age1zw…`.

- [ ] **Step 2: Write `.sops.yaml` at repo root**

Substitute `$AGE_RECIPIENTS` from the prior step.

```yaml
# .sops.yaml
creation_rules:
  - path_regex: tofu/shared/accounts/.*/auth\.yaml$
    encrypted_regex: '^(.*)$'
    age: <PASTE-RECIPIENTS-COMMA-SEPARATED-HERE>
```

Use the actual value, not the placeholder. `encrypted_regex: '^(.*)$'` encrypts every leaf so casual diffs are inert.

- [ ] **Step 3: Verify SOPS picks the rule up**

```bash
mkdir -p /tmp/sops-check/tofu/shared/accounts/oracle/probe
printf 'auth:\n  marker: hello\n' > /tmp/sops-check/tofu/shared/accounts/oracle/probe/auth.yaml
cp .sops.yaml /tmp/sops-check/.sops.yaml
( cd /tmp/sops-check && sops -e -i tofu/shared/accounts/oracle/probe/auth.yaml )
head -3 /tmp/sops-check/tofu/shared/accounts/oracle/probe/auth.yaml
rm -rf /tmp/sops-check
```

Expected: the file content starts with `auth:` but the marker line is replaced with `marker: ENC[AES256_GCM,...]`. If `sops -e` says "no matching creation rule", the path_regex is wrong — fix and retry.

- [ ] **Step 4: Commit on M1 branch**

```bash
git checkout -b feat/repo-resident-auth-m1
git add .sops.yaml
git commit -m "sops: add encryption rule for tofu/shared/accounts/*/auth.yaml"
```

### Task 2: Write `scripts/migrate-auth-to-repo.sh`

**Files:**
- Create: `scripts/migrate-auth-to-repo.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# scripts/migrate-auth-to-repo.sh
#
# One-shot: copy every provider/account auth.yaml out of R2, re-encrypt
# with the repo's .sops.yaml rule, and write into tofu/shared/accounts/.
# Intended to land alongside .sops.yaml in PR M1, then deleted in PR M3.
#
# Prerequisites:
#   - aws CLI with R2 credentials in the environment
#       (AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ACCOUNT_ID)
#   - sops binary on PATH
#   - SOPS_AGE_KEY env var set to the private age key (decrypt contabo)
#   - Run from the repo root
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?required}"
: "${AWS_SECRET_ACCESS_KEY:?required}"
: "${R2_ACCOUNT_ID:?required}"
: "${SOPS_AGE_KEY:?required (for decrypting existing contabo auth.yaml)}"

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
[[ -f .sops.yaml ]] || { echo ".sops.yaml not at repo root — aborting" >&2; exit 1; }

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
BUCKET="cluster-tofu-state"

# Provider → account list comes from tofu/shared/accounts.yaml.
providers=(contabo oracle onprem)
for prov in "${providers[@]}"; do
  mapfile -t accts < <(yq -r ".${prov}[]?" tofu/shared/accounts.yaml)
  for acct in "${accts[@]}"; do
    [[ -z "$acct" ]] && continue
    key="production/inventory/${prov}/${acct}/auth.yaml"
    dest="tofu/shared/accounts/${prov}/${acct}/auth.yaml"
    mkdir -p "$(dirname "$dest")"
    tmp=$(mktemp)
    echo "[$prov/$acct] pulling s3://$BUCKET/$key"
    if ! aws s3 cp "s3://${BUCKET}/${key}" "$tmp" \
        --endpoint-url "$ENDPOINT" --region us-east-1 2>/dev/null; then
      echo "  no auth.yaml in R2 for $prov/$acct — skipping"
      rm -f "$tmp"
      continue
    fi
    if [[ "$prov" == "contabo" ]]; then
      sops -d "$tmp" > "$dest"
    else
      cp "$tmp" "$dest"
    fi
    rm -f "$tmp"
    sops -e -i "$dest"
    echo "  wrote encrypted $dest"
  done
done

echo "Done. Inspect git status and commit."
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/migrate-auth-to-repo.sh
```

- [ ] **Step 3: Commit on M1 branch**

```bash
git add scripts/migrate-auth-to-repo.sh
git commit -m "scripts: add one-shot migrate-auth-to-repo.sh (M1)"
```

### Task 3: Run migration locally, verify, commit

**Files:**
- Create: `tofu/shared/accounts/contabo/bwire/auth.yaml`
- Create: `tofu/shared/accounts/oracle/<each-account>/auth.yaml`

- [ ] **Step 1: Run the migration script**

You need R2 creds and the SOPS age private key in env. Source them however your operator setup does (e.g. `direnv`, `~/.config/sops/age/keys.txt` + `export SOPS_AGE_KEY=$(cat ...)`, `aws-vault`, etc.).

```bash
./scripts/migrate-auth-to-repo.sh
```

Expected output: one "wrote encrypted …" line per provider/account that had an R2 auth.yaml. Onprem entries should print "no auth.yaml in R2" and be skipped.

- [ ] **Step 2: Verify every produced file is SOPS-encrypted**

```bash
find tofu/shared/accounts -name auth.yaml -print0 \
  | xargs -0 -I{} sh -c 'echo "== {} ==" ; head -3 "{}"'
```

Expected: each file's content starts with an `auth:` block whose leaf values are `ENC[AES256_GCM,…]`. If any file has plaintext values, the SOPS rule didn't match — go back to Task 1 Step 3.

- [ ] **Step 3: Verify each file round-trips back to plaintext**

```bash
for f in $(find tofu/shared/accounts -name auth.yaml); do
  echo "== $f =="
  sops -d "$f" | head -5
done
```

Expected: plaintext content for each file. If any decrypt fails, your SOPS_AGE_KEY didn't include the recipient that encrypted that file.

- [ ] **Step 4: Spot-check one file against its R2 origin**

For one oracle account (e.g. `madiang100`), confirm the decrypted body matches the R2 source:

```bash
aws s3 cp s3://cluster-tofu-state/production/inventory/oracle/madiang100/auth.yaml /tmp/r2-orig.yaml \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" --region us-east-1
diff <(sops -d tofu/shared/accounts/oracle/madiang100/auth.yaml) /tmp/r2-orig.yaml
rm /tmp/r2-orig.yaml
```

Expected: empty diff. If non-empty, the migration script lost or mangled something — debug.

- [ ] **Step 5: Commit encrypted auth files**

```bash
git add tofu/shared/accounts/
git commit -m "accounts: seed encrypted auth.yaml for every provider/account (M1)"
```

### Task 4: Open M1 PR and merge

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/repo-resident-auth-m1
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "M1: seed encrypted auth.yaml into tofu/shared/accounts/" \
  --body "$(cat <<'EOF'
## Summary
First of three migration PRs that move provider auth credentials out of R2 into the repo.

- Adds `.sops.yaml` with a path rule covering `tofu/shared/accounts/*/*/auth.yaml`.
- Adds `scripts/migrate-auth-to-repo.sh` (one-shot helper used to produce the commits in this PR).
- Adds 8 SOPS-encrypted `auth.yaml` files (1 contabo + 7 oracle).

## Operational impact
None. No tofu module or workflow reads from these new files yet. The fleet continues to read R2 auth.yaml as today. This PR exists so PR M2 has files to flip the read path to.

## Test plan
- [ ] CI `secrets / run` job passes (validates `SOPS_AGE_KEY` decrypts the new files).
- [ ] `sops -d tofu/shared/accounts/oracle/madiang100/auth.yaml` returns the expected plaintext locally.
- [ ] Every other layer's plan is no-op (the new files exist but no code reads them yet).
EOF
)"
```

- [ ] **Step 3: Verify CI passes and merge**

```bash
gh pr checks
gh pr merge --squash --delete-branch
git checkout main
git pull --ff-only origin main
```

---

## PR M2 — Flip Read Path + Collapse Old Plumbing

Goal: every consumer reads from the repo. R2 auth files become unreferenced. `talos-images.yaml` moves to R2.

### Task 5: Pre-bake `talos-images.yaml` in R2 (operational prep, no commit)

Why: when M2 lands, the tofu reader will look for `talos-images.yaml` at `${var.local_inventory_dir}/talos-images.yaml`. The workflow's pre-plan `aws s3 sync s3://.../production/inventory/ /tmp/inventory/` pulls everything in that prefix, including a top-level `talos-images.yaml` — but only if such an object actually exists. Upload it now so M2's CI doesn't read an empty file.

- [ ] **Step 1: Upload current repo file to R2**

```bash
aws s3 cp tofu/shared/inventory/talos-images.yaml \
  s3://cluster-tofu-state/production/inventory/talos-images.yaml \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
```

Expected: `upload: tofu/shared/inventory/talos-images.yaml to s3://...`.

- [ ] **Step 2: Verify by reading it back**

```bash
aws s3 cp s3://cluster-tofu-state/production/inventory/talos-images.yaml - \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1 | head -10
```

Expected: the YAML matches the repo file's first 10 lines.

### Task 6: Update `node-state` module — drop writers, flip read path

**Files:**
- Modify: `tofu/modules/node-state/main.tf`
- Modify: `tofu/modules/node-state/variables.tf`
- Modify: `tofu/modules/node-state/outputs.tf`

- [ ] **Step 1: Branch off main**

```bash
git checkout main && git pull --ff-only origin main
git checkout -b feat/repo-resident-auth-m2
```

- [ ] **Step 2: Edit `tofu/modules/node-state/main.tf`**

Replace the contents with the following (keeps the nodes + per-node-config writers; rips out the auth writers; reads auth from `tofu/shared/accounts/<provider>/<account>/auth.yaml`):

```hcl
# tofu/modules/node-state/main.tf
#
# Reads per-(provider, account) inventory state.
#
# Auth credentials live in the REPO under tofu/shared/accounts/<provider>/<account>/auth.yaml
# (SOPS-encrypted via .sops.yaml at repo root). Node specs and per-node Talos
# configs live in R2 under production/inventory/<provider>/<account>/.
#
# Auth.yaml is read via the `sops` provider directly from the repo (no R2
# round-trip; no local staging).
# Nodes.yaml is read from the local staging dir populated pre-plan by
# `aws s3 sync s3://.../production/inventory/ <staging>/`.
# Writes for nodes + per-node configs continue to go to R2 via aws_s3_object.

locals {
  base_key  = "${var.key_prefix}/${var.provider_name}/${var.account}"
  nodes_key = "${local.base_key}/nodes.yaml"

  # Repo-resident auth path. Provider+account always present.
  auth_repo = "${path.module}/../../shared/accounts/${var.provider_name}/${var.account}/auth.yaml"

  # Local staged paths for nodes (reads).
  base_local  = "${var.local_inventory_dir}/${var.provider_name}/${var.account}"
  nodes_local = "${local.base_local}/nodes.yaml"

  has_auth  = fileexists(local.auth_repo)
  has_nodes = fileexists(local.nodes_local)
}

# --- encrypted reads (auth) ------------------------------------------------

data "sops_file" "auth" {
  count       = local.has_auth ? 1 : 0
  source_file = local.auth_repo
}

# --- decoded outputs -------------------------------------------------------

locals {
  auth_decoded  = local.has_auth ? data.sops_file.auth[0].data : null
  nodes_decoded = try(yamldecode(file(local.nodes_local)), { nodes = {} })
}

locals {
  inventory_keys = sort(concat(
    local.has_auth ? [local.auth_repo] : [],
    local.has_nodes ? [local.nodes_local] : [],
  ))
}

# --- writers (nodes + per-node configs) -----------------------------------

resource "aws_s3_object" "nodes" {
  count        = var.write_nodes ? 1 : 0
  bucket       = var.bucket
  key          = local.nodes_key
  content      = yamlencode(var.nodes_content)
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = var.nodes_content != null
      error_message = "write_nodes = true but nodes_content is null"
    }
  }
}

resource "aws_s3_object" "per_node_config" {
  for_each = var.write_per_node_configs ? var.per_node_configs_content : {}
  bucket   = var.bucket
  key      = "${local.base_key}/${var.talos_version}/${each.key}.yaml"
  content      = each.value
  content_type = "application/x-yaml"

  lifecycle {
    precondition {
      condition     = !var.write_per_node_configs || var.talos_version != ""
      error_message = "write_per_node_configs = true but talos_version is empty"
    }
  }
}
```

Key changes vs prior version:
- Removed `is_encrypted_auth` switch and the `if local.is_encrypted_auth` fork for the file read.
- Removed `aws_s3_object.auth` and `aws_s3_object.auth_plaintext` resources.
- Replaced `data.sops_file.auth[0].raw + yamldecode` with `data.sops_file.auth[0].data` (the sops provider returns a decoded map directly).
- `auth_repo` replaces `auth_local`.

- [ ] **Step 3: Edit `tofu/modules/node-state/variables.tf`**

Remove the following blocks: `age_recipients`, `write_auth`, `auth_content`. Keep `provider_name`, `account`, `bucket`, `key_prefix`, `local_inventory_dir`, `write_nodes`, `nodes_content`, `write_per_node_configs`, `per_node_configs_content`, `talos_version`.

(Use `Edit` tool to remove only those three variable blocks. The exact lines depend on the file's current layout — open the file and identify each block.)

- [ ] **Step 4: Edit `tofu/modules/node-state/outputs.tf`**

The current outputs reference `local.inventory_keys` which is still computed (now from repo auth path + R2 nodes path). No changes needed unless the `has_files.auth` output's semantics need a docstring update. Verify the file still has:

```hcl
output "auth" { value = local.auth_decoded }
output "nodes" { value = local.nodes_decoded }
output "inventory_keys_found" { value = sort(local.inventory_keys) }
output "has_files" {
  value = {
    auth  = local.has_auth
    nodes = local.has_nodes
  }
}
```

No code change in this step if the file already matches.

- [ ] **Step 5: Local validate**

```bash
cd tofu/modules/node-state && tofu init -backend=false && tofu validate && cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add tofu/modules/node-state/
git commit -m "node-state: read auth from repo, drop R2 auth writers (M2)"
```

### Task 7: Drop `age_recipients` arg passing in layer wirings

**Files:**
- Modify: `tofu/layers/01-contabo-infra/main.tf` (the `module "contabo_account_state"` block)
- Modify: `tofu/layers/02-onprem-infra/main.tf` (the `module "onprem_account_state"` block)
- Modify: `tofu/layers/02-oracle-infra/main.tf` (the `module "oracle_account_state"` block)

- [ ] **Step 1: For each layer file above, remove the `age_recipients` line**

Example diff (layer 02-oracle-infra/main.tf):

```diff
 module "oracle_account_state" {
   for_each            = toset(local.oracle_account_keys)
   source              = "../../modules/node-state"
   provider_name       = "oracle"
   account             = each.key
-  age_recipients      = split(",", var.age_recipients)
   local_inventory_dir = var.local_inventory_dir
 }
```

Repeat for the contabo and onprem layers. (If a layer doesn't pass `age_recipients`, skip it.)

- [ ] **Step 2: Drop the layer-level `age_recipients` variable if it becomes unused**

Open each layer's `variables.tf`. If `var.age_recipients` is no longer referenced anywhere in the layer after Step 1, delete the variable. (Search: `grep -rn 'var\.age_recipients' tofu/layers/<layer>/`.)

- [ ] **Step 3: Local validate each layer**

```bash
for d in tofu/layers/01-contabo-infra tofu/layers/02-onprem-infra tofu/layers/02-oracle-infra ; do
  ( cd "$d" && tofu init -backend=false >/dev/null && tofu validate )
done
```

Expected: `Success! The configuration is valid.` for each.

- [ ] **Step 4: Commit**

```bash
git add tofu/layers/01-contabo-infra/ tofu/layers/02-onprem-infra/ tofu/layers/02-oracle-infra/
git commit -m "layers: drop age_recipients arg on node-state (M2)"
```

### Task 8: Repoint `talos-images.yaml` reader to R2 staging dir

**Files:**
- Modify: `tofu/layers/01-contabo-infra/image.tf:16`
- Modify: `tofu/modules/oracle-account-infra/image.tf:30`

- [ ] **Step 1: Edit `tofu/layers/01-contabo-infra/image.tf`**

```diff
-  talos_images = yamldecode(file("${path.module}/../../shared/inventory/talos-images.yaml"))
+  talos_images = yamldecode(file("${var.local_inventory_dir}/talos-images.yaml"))
```

Confirm `var.local_inventory_dir` exists in the layer. If it doesn't, add it to the layer's `variables.tf`:

```hcl
variable "local_inventory_dir" {
  type        = string
  description = "Local dir populated pre-plan via `aws s3 sync s3://cluster-tofu-state/production/inventory/` (pulls talos-images.yaml + per-account nodes.yaml)."
}
```

And confirm `terraform.tfvars` (or the workflow's `-var` flag) sets it.

- [ ] **Step 2: Add `local_inventory_dir` variable to `tofu/modules/oracle-account-infra/variables.tf`**

This module does NOT have the variable today (confirmed via grep). Append:

```hcl
variable "local_inventory_dir" {
  type        = string
  description = "Local dir populated pre-plan via `aws s3 sync s3://cluster-tofu-state/production/inventory/`. The module reads `${local_inventory_dir}/talos-images.yaml` to resolve the per-account image OCID."
}
```

- [ ] **Step 3: Pass `local_inventory_dir` from the layer call site**

Edit `tofu/layers/02-oracle-infra/main.tf` → `module "oracle_account"` block. Add the line among the other arguments:

```diff
 module "oracle_account" {
   for_each  = local.oci_accounts_effective
   source    = "../../modules/oracle-account-infra"
   providers = { oci = oci.account[each.key] }

   account_key                          = each.key
+  local_inventory_dir                  = var.local_inventory_dir
   compartment_ocid                     = try(each.value.compartment_ocid, "")
   ...
 }
```

- [ ] **Step 4: Edit `tofu/modules/oracle-account-infra/image.tf`**

```diff
-  talos_images = yamldecode(file("${path.module}/../../shared/inventory/talos-images.yaml"))
+  talos_images = yamldecode(file("${var.local_inventory_dir}/talos-images.yaml"))
```

- [ ] **Step 5: Local validate**

```bash
for d in tofu/layers/01-contabo-infra tofu/layers/02-oracle-infra ; do
  ( cd "$d" && tofu init -backend=false >/dev/null && tofu validate )
done
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Commit**

```bash
git add tofu/layers/01-contabo-infra/ tofu/layers/02-oracle-infra/ tofu/modules/oracle-account-infra/
git commit -m "talos-images: read from R2 staging dir, not repo (M2)"
```

### Task 9: Delete `tofu/shared/inventory/`

**Files:**
- Delete: `tofu/shared/inventory/talos-images.yaml`
- Delete: `tofu/shared/inventory/` (empty dir)

- [ ] **Step 1: Verify the R2 copy is in place before deleting the repo copy**

```bash
aws s3 ls s3://cluster-tofu-state/production/inventory/talos-images.yaml \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" --region us-east-1
```

Expected: one line matching the object size. If empty, go back to Task 5.

- [ ] **Step 2: Remove the file from git**

```bash
git rm tofu/shared/inventory/talos-images.yaml
rmdir tofu/shared/inventory 2>/dev/null || true
```

- [ ] **Step 3: Commit**

```bash
git commit -m "talos-images: drop repo copy now that R2 is authoritative (M2)"
```

### Task 10: Rewire `sync-talos-images.yml` — write to R2 instead of opening a PR

**Files:**
- Modify: `.github/workflows/sync-talos-images.yml` (the `assemble-and-pr` job at the bottom and the prior `stored=$(yq … talos-images.yaml)` step)

- [ ] **Step 1: Rename job + remove gh PR permission**

In the `assemble-and-pr` job header, change the job name (key in `jobs:`) from `assemble-and-pr` to `assemble-and-upload`. Remove the `permissions: pull-requests: write` line (only `contents: read` remains).

- [ ] **Step 2: Replace the rendering output path**

Find the step that does `> tofu/shared/inventory/talos-images.yaml` (and the subsequent `>> tofu/shared/inventory/talos-images.yaml` appends) and change them to a working-tree-relative path like `/tmp/talos-images.yaml`:

```diff
-          } > tofu/shared/inventory/talos-images.yaml
+          } > /tmp/talos-images.yaml
```

Apply the same path change to every `>>` line and the final `cat …` diagnostic in the same step.

- [ ] **Step 3: Replace `gh pr create` block with `aws s3 cp`**

Delete the entire git/PR step (commit, branch, push, gh pr create) and replace it with:

```yaml
      - name: Upload talos-images.yaml to R2
        env:
          AWS_ACCESS_KEY_ID:     ${{ secrets.R2_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          R2_ACCOUNT_ID:         ${{ secrets.R2_ACCOUNT_ID }}
        run: |
          set -euo pipefail
          aws s3 cp /tmp/talos-images.yaml \
            s3://cluster-tofu-state/production/inventory/talos-images.yaml \
            --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
            --region us-east-1
          echo "::notice::uploaded production/inventory/talos-images.yaml"
```

- [ ] **Step 4: Drop the "no-op when unchanged" gate at the workflow top**

Find the step (~line 223 in current file) that compares `stored=$(yq -r '.schematic_id // ""' tofu/shared/inventory/talos-images.yaml)` and short-circuits when the schematic hasn't changed. Either delete it (every run is a full sync now), OR adapt it to read the schematic from R2 via `aws s3 cp ... -` and a `yq` pipe. Simplest: delete the gate and let `oci-import`'s display-name-keyed reuse-or-create logic provide the no-op semantics. Document with a code comment that the gate moved into the import job.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/sync-talos-images.yml
git commit -m "sync-talos-images: write to R2 instead of opening a bot PR (M2)"
```

### Task 11: Slim `upload-inventory.yml` to nodes-only

**Files:**
- Modify: `.github/workflows/upload-inventory.yml`

- [ ] **Step 1: Drop `auth.yaml` from filename choice**

```diff
       filename:
         description: "File name in the account dir"
         required: true
         type: choice
-        options: [auth.yaml, nodes.yaml]
+        options: [nodes.yaml]
```

- [ ] **Step 2: Remove the contabo SOPS encryption branch**

Find the step `Install sops (only needed for contabo auth)` and delete the whole step. Then in the "Decode + … + upload" step, remove the `if [[ "$PROVIDER" = "contabo" && "$FILENAME" = "auth.yaml" ]]; then … sops -e … else …` branch and unconditionally `cp "$tmp_plain" "$tmp_out"`.

- [ ] **Step 3: Drop `SOPS_AGE_KEY` and `SOPS_AGE_RECIPIENTS` env vars from this workflow**

```diff
       SOPS_AGE_KEY:             ${{ secrets.SOPS_AGE_KEY }}
       SOPS_AGE_RECIPIENTS:      ${{ vars.SOPS_AGE_RECIPIENTS }}
```

Remove both lines.

- [ ] **Step 4: Update the filename case-check**

```diff
-          case "$FILENAME" in auth.yaml|nodes.yaml) ;; *) echo "::error::bad filename"; exit 2 ;; esac
+          case "$FILENAME" in nodes.yaml) ;; *) echo "::error::bad filename"; exit 2 ;; esac
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/upload-inventory.yml
git commit -m "upload-inventory: drop auth.yaml support, nodes-only now (M2)"
```

### Task 12: Tofu plan verification (no-op check)

This is the operational safety gate. Every layer's plan against `main + this branch` must be either zero changes or only the predictable changes the spec calls out (in this case: no resource changes — auth content is identical, just sourced from a different file).

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/repo-resident-auth-m2
```

- [ ] **Step 2: Open PR (draft) to trigger CI plans**

```bash
gh pr create --draft --title "M2: flip auth read path to repo + relocate talos-images.yaml to R2" \
  --body "Operational cutover. Tofu plan should be no-op for fleet resources."
```

- [ ] **Step 3: Wait for `tofu-plan` matrix to complete**

```bash
gh pr checks --watch
```

- [ ] **Step 4: For each `*-infra (account)` matrix cell, download the plan artifact and inspect**

```bash
gh run download <run-id> -n tfplan-02-oracle-infra-madiang100
tofu show -json tfplan | jq '[.resource_changes[] | select(.change.actions[] != "no-op") | {address, actions}]'
```

Expected: `[]` (empty list) for every layer/account cell.

If a cell shows non-no-op changes, halt the merge. Investigate; the most likely cause is an auth.yaml decryption that produced subtly different content (e.g. quoted-vs-unquoted bool/number) than the prior R2 read.

- [ ] **Step 5: Mark PR ready and merge**

```bash
gh pr ready
gh pr merge --squash --delete-branch
git checkout main && git pull --ff-only origin main
```

- [ ] **Step 6: Trigger a real apply on one cell to confirm**

```bash
gh workflow run tofu-apply.yml
gh run watch
```

Inspect the `oracle-infra (madiang100)` apply log: it should report no resource changes. Smoke-test other layers' applies similarly.

---

## Bootstrap Script — Auto-PR Tail

Goal: `scripts/bootstrap-oci-oidc.sh` ends with a pushed branch and a printed PR URL.

### Task 13: Add new flags + repo-path detection

**Files:**
- Modify: `scripts/bootstrap-oci-oidc.sh`

- [ ] **Step 1: Branch off main**

```bash
git checkout main && git pull --ff-only origin main
git checkout -b feat/bootstrap-self-pr
```

- [ ] **Step 2: Add new defaults near the existing default block (around line 80)**

Add these lines among the existing defaults (`PROFILE`, `SUFFIX`, etc.):

```bash
REPO_PATH=""
BRANCH=""
NO_PUSH="false"
```

- [ ] **Step 3: Add new flag parsing in the `while` loop (around line 93)**

Add these cases inside the `case $1 in` block:

```bash
    --repo-path)    REPO_PATH="$2"; shift 2 ;;
    --branch)       BRANCH="$2"; shift 2 ;;
    --no-push)      NO_PUSH="true"; shift ;;
```

- [ ] **Step 4: Remove the now-unused `--repo` and `--branch GH_REPO/GH_BRANCH` flags**

Find and delete the existing `--repo` and `--branch` cases plus their initialization (`GH_REPO=…`, `GH_BRANCH=…`). They were used only to render the inventory stanza header text, which is going away.

- [ ] **Step 5: Add required-tool check for `git` and `sops`**

In the `for cmd in oci jq curl python3 ; do` loop, append `git sops`:

```bash
for cmd in oci jq curl python3 git sops ; do
```

- [ ] **Step 6: Add repo-path resolution helper near the start of `main` execution flow**

Insert this block right after the required-tool check (after the `for cmd` loop, before `say()`/`warn()`/`die()` definitions move to action):

```bash
# Resolve repo root. Default: detect via git rev-parse from pwd. Fail fast
# if the detected root doesn't contain .sops.yaml (likely wrong checkout).
if [[ -z "$REPO_PATH" ]]; then
  REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [[ -z "$REPO_PATH" ]] && die "Not inside a git repo; pass --repo-path PATH explicitly"
fi
[[ -f "$REPO_PATH/.sops.yaml" ]] \
  || die "$REPO_PATH has no .sops.yaml — wrong checkout? Aborting before any write."
```

- [ ] **Step 7: Commit**

```bash
git add scripts/bootstrap-oci-oidc.sh
git commit -m "bootstrap: add --repo-path / --branch / --no-push flags + repo guard"
```

### Task 14: Replace stdout YAML with file-write + sops + commit + push

**Files:**
- Modify: `scripts/bootstrap-oci-oidc.sh` (the section ~line 813+ — "EMIT INVENTORY STANZA")

- [ ] **Step 1: Replace the "EMIT INVENTORY STANZA" block**

Find the section labelled `# =========================================================================` followed by `# 7. EMIT INVENTORY STANZA` (around line 811). Replace from there through the closing `printf '%s\n' "$inventory_yaml"` with the following:

```bash
# =========================================================================
# 7. WRITE ENCRYPTED auth.yaml + EDIT accounts.yaml + COMMIT + PUSH
# =========================================================================
say ""
say "=========================================================="
say "OCI workload identity federation ready for profile [$PROFILE]."

DEFAULT_BRANCH="onboard-oracle-${GH_PROFILE}"
BRANCH="${BRANCH:-$DEFAULT_BRANCH}"
AUTH_DIR="$REPO_PATH/tofu/shared/accounts/oracle/$GH_PROFILE"
AUTH_FILE="$AUTH_DIR/auth.yaml"
ACCOUNTS_FILE="$REPO_PATH/tofu/shared/accounts.yaml"

mkdir -p "$AUTH_DIR"

# Build the plaintext auth body.
cat > "$AUTH_FILE" <<EOF
auth:
  tenancy_ocid: ${TENANCY_OCID}
  region: ${REGION}
  compartment_ocid: ${COMPARTMENT_OCID}
  vcn_cidr: ${VCN_CIDR:-10.200.0.0/16}
  enable_ipv6: true
  auth_method: SecurityToken
  domain_base_url: ${DOMAIN_BASE_URL}
  oidc_client_identifier: "${CLIENT_ID}:${CLIENT_SECRET:-<PASTE_CLIENT_SECRET>}"
EOF

# Encrypt in place via the repo's .sops.yaml rule.
( cd "$REPO_PATH" && sops -e -i "tofu/shared/accounts/oracle/$GH_PROFILE/auth.yaml" )
say "wrote encrypted $AUTH_FILE"

# Idempotently add the account name under oracle: in accounts.yaml.
if ! grep -qE "^\s*-\s+${GH_PROFILE}\s*$" "$ACCOUNTS_FILE"; then
  python3 - "$ACCOUNTS_FILE" "$GH_PROFILE" <<'PY'
import sys, re
path, name = sys.argv[1], sys.argv[2]
text = open(path).read()
# Insert under "oracle:" preserving comments and order.
out_lines = []
inserted = False
in_oracle = False
for line in text.splitlines():
    out_lines.append(line)
    if re.match(r'^oracle:\s*$', line):
        in_oracle = True
        continue
    if in_oracle and not line.startswith('  -') and not line.startswith('  #') and line.strip() != '':
        # We've left the oracle block without inserting; insert before this line.
        out_lines.insert(-1, f"  - {name}")
        in_oracle = False
        inserted = True
if in_oracle and not inserted:
    out_lines.append(f"  - {name}")
open(path, 'w').write('\n'.join(out_lines) + '\n')
PY
  say "added '$GH_PROFILE' to oracle: in tofu/shared/accounts.yaml"
else
  say "'$GH_PROFILE' already in accounts.yaml — skipping edit"
fi

# Create branch, commit, push.
cd "$REPO_PATH"
git checkout -b "$BRANCH"
git add tofu/shared/accounts/oracle/"$GH_PROFILE"/auth.yaml tofu/shared/accounts.yaml
git commit -m "onboard oracle ${GH_PROFILE}: add to accounts.yaml + encrypted auth"

if [[ "$NO_PUSH" = "true" ]]; then
  say "branch '$BRANCH' committed locally — skipping push (--no-push)"
else
  # Capture stderr to extract the PR-create URL git prints.
  push_log=$(git push -u origin "$BRANCH" 2>&1)
  printf '%s\n' "$push_log"
  pr_url=$(printf '%s\n' "$push_log" | grep -oE 'https://github.com/[^ ]+/pull/new/[^ ]+' | head -1)
  if [[ -z "$pr_url" ]]; then
    # Fallback: synthesize from origin URL + branch.
    origin=$(git config --get remote.origin.url)
    slug=$(printf '%s' "$origin" | sed -E 's#.*[/:]([^/]+/[^/]+)\.git$#\1#')
    pr_url="https://github.com/$slug/compare/$BRANCH?expand=1"
  fi
  say ""
  say "OPEN: $pr_url"
fi
```

- [ ] **Step 2: Verify the BUDGET + ALERT block still executes**

Open `scripts/bootstrap-oci-oidc.sh` and confirm the section labelled `# 8. BUDGET + ALERT (cost guardrail)` is intact and ordered after the new commit/push step. If the original ordering placed budget before the inventory stanza, leave it in place (commit/push doesn't depend on budget; both can run independently). No code change in this step unless the budget section was accidentally removed during Step 1's replacement.

- [ ] **Step 3: Verify the script is still syntactically valid**

```bash
bash -n scripts/bootstrap-oci-oidc.sh
```

Expected: no output (means no syntax errors).

- [ ] **Step 4: Update the script header comment to match the new behaviour**

In the comment block at the top of `scripts/bootstrap-oci-oidc.sh`, replace the "Each invocation prints an OCI account stanza" paragraph with:

```bash
# Each invocation:
#   1. Configures the OCI Identity Domain (service user, group, policy,
#      OAuth app, identity propagation trust, monthly budget) idempotently.
#   2. Writes a SOPS-encrypted auth.yaml into the operator's local
#      deployment.infra checkout under tofu/shared/accounts/oracle/<gh-profile>/.
#   3. Edits tofu/shared/accounts.yaml to add the new account.
#   4. Creates a branch, commits, and pushes. Prints the "Create PR" URL.
#
# No GitHub auth (no `gh` CLI, no GITHUB_TOKEN) is needed. Plain `git push`
# over the operator's existing SSH/HTTPS credentials is sufficient.
```

- [ ] **Step 5: Commit**

```bash
git add scripts/bootstrap-oci-oidc.sh
git commit -m "bootstrap: write encrypted auth.yaml + accounts.yaml edit + push branch (M2)"
```

### Task 15: Integration test on a throwaway OCI tenancy

This task is partially manual — requires an OCI tenancy that the operator can blow away after.

- [ ] **Step 1: Pick a throwaway tenancy or use madiang100 (already onboarded)**

Re-running against `madiang100` is safe because every OCI step is idempotent — the script will detect existing resources and no-op. The repo writes will produce a no-op git diff if the auth content matches what M1 already committed; if any field differs, the operator can inspect.

```bash
./scripts/bootstrap-oci-oidc.sh \
  --profile madiang100 \
  --gh-profile madiang100 \
  --no-push
```

- [ ] **Step 2: Inspect the local state**

```bash
git status
git diff --cached
```

Expected: a branch `onboard-oracle-madiang100` (or whatever you set) with two changes: an updated `tofu/shared/accounts/oracle/madiang100/auth.yaml` (encrypted; might match exactly if the bootstrap re-emits the same content) and a no-op or duplicate `accounts.yaml` edit.

- [ ] **Step 3: Decrypt and verify content**

```bash
sops -d tofu/shared/accounts/oracle/madiang100/auth.yaml | head -10
```

Expected: the auth body the script wrote (tenancy_ocid, region, etc.) matches what's in OCI.

- [ ] **Step 4: Reset the test branch**

```bash
git checkout main
git branch -D onboard-oracle-madiang100
```

- [ ] **Step 5: Now do a real test with push to a fresh branch**

Re-run, this time without `--no-push`:

```bash
./scripts/bootstrap-oci-oidc.sh \
  --profile madiang100 \
  --gh-profile madiang100-test
```

Expected: branch pushed; script prints "OPEN: https://github.com/stawi-org/deployment.infra/pull/new/onboard-oracle-madiang100-test" or similar. Open the URL, confirm the PR diff makes sense, then close the PR + delete the branch (it was a test):

```bash
gh pr close <number> --delete-branch
```

### Task 16: Open + merge bootstrap-script PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/bootstrap-self-pr
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "bootstrap-oci-oidc: write encrypted auth + commit + push instead of printing stanza" \
  --body "$(cat <<'EOF'
## Summary
After M2 landed, the bootstrap script can produce a fully-formed onboarding PR on its own. This change:
- Adds `--repo-path`, `--branch`, `--no-push` flags.
- Replaces the "Rendered OCI inventory stanza" stdout block with:
  - Write `tofu/shared/accounts/oracle/<gh_profile>/auth.yaml` from the auth body.
  - `sops -e -i` to encrypt via the repo's `.sops.yaml` rule.
  - Append the account name to `tofu/shared/accounts.yaml`.
  - `git checkout -b onboard-oracle-<gh_profile>`, commit both files, push.
  - Capture/print the GitHub "Create PR" URL — no `gh` CLI, no GitHub token needed.
- Requires `git` and `sops` on the operator's machine (failing fast if absent).
- Updates the script's header comment to describe the new behaviour.

## Test plan
- [ ] `bash -n scripts/bootstrap-oci-oidc.sh` passes.
- [ ] Dry-run against madiang100 with `--no-push` produces a clean local branch with the expected diff.
- [ ] Real run with a throwaway `--gh-profile` value pushes the branch and prints the create-PR URL.
EOF
)"
gh pr merge --squash --delete-branch
git checkout main && git pull --ff-only origin main
```

---

## PR M3 — Optional R2 Cleanup

Goal: delete the now-unreferenced R2 auth.yaml objects.

### Task 17: Add `cleanup-r2-auth.yml` workflow

**Files:**
- Create: `.github/workflows/cleanup-r2-auth.yml`

- [ ] **Step 1: Branch off main**

```bash
git checkout main && git pull --ff-only origin main
git checkout -b feat/repo-resident-auth-m3
```

- [ ] **Step 2: Create the workflow**

```yaml
# .github/workflows/cleanup-r2-auth.yml
# One-shot opt-in cleanup: deletes every production/inventory/<provider>/<account>/auth.yaml
# object from R2. Run this only AFTER PR M2 has landed and several clean
# tofu-apply cycles confirm the repo-resident auth path is healthy.
name: cleanup-r2-auth
on:
  workflow_dispatch:
    inputs:
      confirm:
        description: 'Type DELETE to confirm'
        required: true
        type: string

jobs:
  cleanup:
    runs-on: ubuntu-latest
    if: inputs.confirm == 'DELETE'
    permissions:
      contents: read
    env:
      AWS_ACCESS_KEY_ID:        ${{ secrets.R2_ACCESS_KEY_ID }}
      AWS_SECRET_ACCESS_KEY:    ${{ secrets.R2_SECRET_ACCESS_KEY }}
      AWS_EC2_METADATA_DISABLED: "true"
      R2_ACCOUNT_ID:            ${{ secrets.R2_ACCOUNT_ID }}
    steps:
      - uses: actions/checkout@v5
      - name: Install yq
        run: |
          sudo curl -fsSL -o /usr/local/bin/yq \
            https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
          sudo chmod +x /usr/local/bin/yq
      - name: Delete every <provider>/<account>/auth.yaml from R2
        run: |
          set -euo pipefail
          ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
          for prov in contabo oracle onprem ; do
            mapfile -t accts < <(yq -r ".${prov}[]?" tofu/shared/accounts.yaml)
            for acct in "${accts[@]}"; do
              [[ -z "$acct" ]] && continue
              key="production/inventory/${prov}/${acct}/auth.yaml"
              echo "::notice::deleting $key"
              aws s3 rm "s3://cluster-tofu-state/${key}" \
                --endpoint-url "$ENDPOINT" --region us-east-1 \
                || echo "  (already absent for $prov/$acct)"
            done
          done
```

- [ ] **Step 3: Delete the now-stale migration script**

```bash
git rm scripts/migrate-auth-to-repo.sh
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/cleanup-r2-auth.yml
git commit -m "M3: add R2-auth cleanup workflow + drop migrate script"
```

### Task 18: Open + merge M3 PR; run the cleanup workflow

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/repo-resident-auth-m3
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "M3: add cleanup-r2-auth workflow; drop migrate-auth-to-repo script" \
  --body "Opt-in cleanup. Adds a workflow_dispatch that deletes every R2 auth.yaml object. Drops the one-shot migration script."
```

- [ ] **Step 3: Merge after review**

```bash
gh pr merge --squash --delete-branch
git checkout main && git pull --ff-only origin main
```

- [ ] **Step 4: Run the cleanup workflow (manually)**

```bash
gh workflow run cleanup-r2-auth.yml -f confirm=DELETE
gh run watch
```

Expected: a "deleting production/inventory/<provider>/<account>/auth.yaml" notice for each provider/account; final status `success`. R2 inventory now contains only nodes.yaml, per-node Talos configs, and talos-images.yaml — no auth files.

- [ ] **Step 5: Spot-check R2 to confirm**

```bash
aws s3 ls s3://cluster-tofu-state/production/inventory/oracle/ --recursive \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" --region us-east-1 \
  | grep auth.yaml || echo "no auth.yaml left under oracle/ — good"
```

Expected: "no auth.yaml left under oracle/".

---

## Done

After M3 runs cleanly, the architecture matches the spec end-state:

- Repo holds account registry + encrypted auth (`tofu/shared/accounts*`).
- R2 holds dynamic inventory (`nodes.yaml`, per-node Talos configs, `talos-images.yaml`).
- `bootstrap-oci-oidc.sh` produces a complete onboarding PR.
- The `sync-talos-images` workflow no longer opens bot PRs.
- `upload-inventory` handles nodes only.

Operators can recover auth values at any time via `sops -d tofu/shared/accounts/<provider>/<account>/auth.yaml` from any checkout.
