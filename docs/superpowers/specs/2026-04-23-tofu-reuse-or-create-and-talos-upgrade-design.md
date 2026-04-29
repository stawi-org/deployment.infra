# Tofu Reuse-or-Create and Talos Upgrade — Design

Date: 2026-04-23
Status: Draft — pending user review

## Problem

Three compounding failures are blocking the `tofu-apply` GitHub Actions workflow and preventing the cluster from reaching equilibrium:

1. **Apply is hard-failing** for all three Contabo control-plane nodes with
   `Error: Configuration for import target does not exist —
   module.nodes["kubernetes-controlplane-api-*"].contabo_instance.this`.
   Root cause: `tofu/layers/01-contabo-infra/imports.tf` hardcodes three Contabo
   instance IDs (`202727783`, `202727782`, `202727781`) that were destroyed by a
   `reset-cluster` workflow run, and re-applying points the `import` block at
   instances that no longer exist.
2. **Credential leak in workflow logs.** `TF_VAR_contabo_accounts` is exported
   to GitHub Actions as a single JSON blob containing a nested `auth` object
   with `oauth2_client_id`, `oauth2_client_secret`, `oauth2_user`, and
   `oauth2_pass`. GitHub's automatic secret masking does not reach into nested
   JSON, so the credentials print in plaintext on every `##[endgroup]` env dump.
   In the failed run `72769913330` alone the blob appears three times.
3. **No Talos upgrade path.** `tofu/modules/node-contabo/main.tf:16-23`
   explicitly flags "`talosctl upgrade` path (TODO: implement)". A version bump
   in `tofu/shared/versions.auto.tfvars` today forces either no-op or a disk
   wipe via `ensure-image.sh`; there is no in-place upgrade that preserves
   etcd, volumes, and workloads.

The operator goal: a single `tofu apply` that brings every provider to
equilibrium without manual intervention. For Contabo and Oracle: reuse running
instances when present, create them when not. For on-prem: config-only, no
provisioning. For all providers: generate a per-node machine configuration,
persist it to the state bucket, and apply it — or, if the Talos version has
changed, upgrade the node in place.

## Goals

- A GitHub Actions `tofu-apply` run succeeds against the existing cluster
  without operator intervention, whether or not the three Contabo CPs are
  already provisioned.
- Running `tofu apply` a second time with no inputs changed produces zero
  resource diffs (idempotent).
- A version bump in `tofu/shared/versions.auto.tfvars` triggers `talosctl
  upgrade --preserve` on every affected node; no disk wipe.
- No credentials appear in workflow logs.
- R2 holds a single, auditable source of truth for intent (`nodes.yaml`,
  `auth.yaml`) and observation (`state.yaml`, `talos-state.yaml`,
  `machine-configs.yaml`).

## Non-goals

- On-prem node provisioning. On-prem remains config-only. Operators apply
  generated Talos machine configs manually (the current `publish-talos-configs`
  flow is preserved).
- Multi-cluster / multi-environment support. Production is the only
  environment in scope.
- Re-architecting the workflow layering. The 00-04 layer graph stays as-is.
- Replacing the `contabo/contabo` provider. The provider's reinstall path
  remains broken (documented in `modules/node-contabo/main.tf`) and we continue
  to work around it with `ensure-image.sh`; this design adds nothing to that
  path.
- Automated recipient rotation. Adding/removing age recipients stays a manual
  operator action (with CI-surfaced feedback via the SOPS validation fixture).

## Architecture overview

Four changes, bounded by R2 as the single source of truth.

1. A new **R2 inventory tree** at `s3://cluster-tofu-state/production/inventory/`
   replaces the aggregated `TF_VAR_*_accounts` JSON blobs. Per-provider,
   per-account files carry credentials (encrypted), declared inventory,
   observed state, and rendered machine configurations.
2. A new **`tofu/modules/node-state/`** module encapsulates
   read-from-R2 / write-to-R2 of the inventory files, with SOPS encryption
   validated at plan time.
3. **Layer 01 (Contabo)** and **Layer 02 (Oracle)** switch from hardcoded
   import blocks to dynamic imports driven by `state.yaml`. If an instance ID
   is already stored, the layer imports and reuses; if not, it creates. After
   apply, the layer writes observed state back to R2.
4. **Layer 03 (Talos)** renders per-node Talos machine configs into
   `machine-configs.yaml` (encrypted), applies them via
   `talos_machine_configuration_apply`, and — when the stored
   `last_applied_talos_version` differs from `var.talos_version` — runs
   `talosctl upgrade --preserve` via a null_resource before the apply. Layer 03
   writes `talos-state.yaml` back to R2.

## R2 inventory layout

```
s3://cluster-tofu-state/production/inventory/<provider>/<account>/
├── auth.yaml              ⚠ age-encrypted   credentials  (contabo only; oracle = plaintext pointers)
├── nodes.yaml             plaintext         declared node inventory (operator intent)
├── state.yaml             plaintext         observed provider state (instance IDs, IPs, status)
├── talos-state.yaml       plaintext         observed Talos state (last-applied version, hash, run id)
└── machine-configs.yaml   ⚠ age-encrypted   rendered Talos machine_configuration per node (apply artifact)
```

Ownership: each file has exactly one writer layer. No two layers ever write to
the same key.

| File | Read by | Written by |
|------|---------|------------|
| `auth.yaml` | the layer that owns that provider | `scripts/seed-inventory.sh` (CI, first apply only; operators for rotations) |
| `nodes.yaml` | the layer that owns that provider, and layer 03 | `scripts/seed-inventory.sh` (CI, first apply only; operators for edits) |
| `state.yaml` | the layer that owns that provider | the layer that owns that provider |
| `talos-state.yaml` | layer 03 | layer 03 |
| `machine-configs.yaml` | layer 03 (to diff against `target_talos_version`); `publish-talos-configs.yml` to bundle for on-prem operators | layer 03 |

On-prem has no `auth.yaml`.

## File schemas

### `auth.yaml`

Contabo (age-encrypted):
```yaml
provider: contabo
account: stawi-contabo
auth:
  oauth2_client_id: INT-XXXXXXXX
  oauth2_client_secret: <secret>
  oauth2_user: <contabo-account-email>
  oauth2_pass: <secret>
```

Oracle (plaintext — all sensitive material is minted at runtime via GitHub
OIDC → OCI workload identity federation):
```yaml
provider: oracle
account: stawi
auth:
  tenancy_ocid: ocid1.tenancy.oc1..aaa...
  compartment_ocid: ocid1.compartment.oc1..bbb...
  region: us-ashburn-1
  config_file_profile: stawi        # matches profile written by configure-oci-wif.sh
  auth_method: SecurityToken        # SecurityToken (CI/WIF) | ApiKey (local dev)
```

### `nodes.yaml`

Contabo:
```yaml
provider: contabo
account: stawi-contabo
labels:      { node.antinvestor.io/capacity-pool: control-plane }
annotations: { node.antinvestor.io/account-owner: platform }
nodes:
  kubernetes-controlplane-api-1:
    role: controlplane                # controlplane | worker
    product_id: V94
    region: EU
    labels:      { ... }
    annotations: { ... }
  # ...
```

Oracle — same shape, fields: `role`, `shape`, `ocpus`, `memory_gb`, plus
account-level `vcn_cidr`, `enable_ipv6`, `bastion_client_cidr_block_allow_list`.

On-prem — no provisioning fields; `role`, `region`, `labels`, `annotations` only.

### `state.yaml`

```yaml
provider: contabo
account: stawi-contabo
nodes:
  kubernetes-controlplane-api-1:
    provider_data:
      contabo_instance_id: "202727783"       # or oci_instance_ocid for Oracle
      product_id: V94                        # or shape/ocpus/memory_gb for Oracle
      region: EU
      ipv4: 1.2.3.4
      ipv6: 2a02:...::1
      status: running
      created_at: 2026-04-22T10:15:00Z
      discovered_at: 2026-04-23T20:42:00Z
```

On-prem `state.yaml` holds operator-declared addressing (if any) and stays
mostly empty.

### `talos-state.yaml`

```yaml
provider: contabo
account: stawi-contabo
nodes:
  kubernetes-controlplane-api-1:
    last_applied_version: v1.12.6
    last_applied_at:      2026-04-23T21:05:00Z
    last_applied_run_id:  "24856280965"
    config_hash:          sha256:abc...       # sha256 of machine-configs.yaml[node].machine_configuration
```

### `machine-configs.yaml`

```yaml
provider: contabo
account: stawi-contabo
nodes:
  kubernetes-controlplane-api-1:
    target_talos_version: v1.12.6
    schematic_id:         <sha256>
    rendered_at:          2026-04-23T21:04:55Z
    rendered_by_run_id:   "24856280965"
    machine_type:         controlplane        # controlplane | worker
    machine_configuration: |
      # full rendered Talos YAML — consumed verbatim by talos_machine_configuration_apply
```

## Components

### `tofu/modules/node-state/`

Purpose: single point of integration with R2 for reading/writing the inventory
tree, with SOPS decrypt/encrypt for the sensitive files.

Inputs: `provider_name` (contabo | oracle | onprem — `provider` is a reserved
meta-argument and cannot be used as a variable name), `account`,
`age_recipient` (for writes), `bucket` and `endpoint` (backend-inherited
defaults).

Outputs:
- `auth`           — decoded `auth.yaml` (or `null` if missing)
- `nodes`          — decoded `nodes.yaml` (or `{ nodes: {} }`)
- `state`          — decoded `state.yaml` (or `{ nodes: {} }`)
- `talos_state`    — decoded `talos-state.yaml` (or `{ nodes: {} }`)
- `machine_configs` — decoded `machine-configs.yaml` (or `{ nodes: {} }`)

Variadic writer resources: the module exposes five named `aws_s3_object.*`
resources (`auth_writer`, `nodes_writer`, `state_writer`, `talos_state_writer`,
`machine_configs_writer`). Each is `count = var.write_<name> ? 1 : 0`, so
callers opt into exactly the subtree they own. This keeps ownership explicit
and avoids two layers racing on the same key.

Read implementation uses `data "aws_s3_object"` with `try(..., "")` wrapping so
a missing object is treated as empty. SOPS decryption uses the `sops_file`
data source from the `carlpett/sops` provider.

Write implementation uses `aws_s3_object` with deterministic
`yamlencode(sorted-map)` content. Encrypted files are encrypted via the SOPS
provider's `sops::encrypt` function (OpenTofu 1.8+ provider-defined function)
against the configured age recipient set.

### `scripts/seed-inventory.sh`

Purpose: first-apply bootstrap. Runs inside CI as a conditional step when
`aws s3 ls s3://cluster-tofu-state/production/inventory/` returns empty.

Inputs read from the repo and CI:
- `tofu/shared/inventory/` — operator-authored node list (existing HCL/YAML, parsed as the source of intent for `nodes.yaml`).
- `tofu/shared/bootstrap/contabo-instance-ids.yaml` — one-time fallback file carrying the three hardcoded IDs currently in `imports.tf`, in the same shape as `state.yaml`. Committed as part of the first seed PR; deleted in the cleanup PR.
- CI secrets: Contabo OAuth2 creds (`CONTABO_OAUTH2_*`), OCI WIF session, age recipient (`SOPS_AGE_RECIPIENT`).

Behavior:
1. Render `nodes.yaml` for each provider/account from `tofu/shared/inventory/`.
2. For each Contabo and Oracle account, query the provider API to resolve declared display_names / shapes to live instance IDs:
   - Contabo: `GET /v1/compute/instances?displayName=<name>` authed with the OAuth2 creds from CI secrets.
   - Oracle: `oci compute instance list --compartment-id=...` with WIF session token.
3. For any Contabo node that fails the lookup, fall back to `tofu/shared/bootstrap/contabo-instance-ids.yaml`.
4. Render `state.yaml` with the resolved `provider_data`.
5. Render `auth.yaml` from CI secrets and encrypt via `sops -e -i --age "$SOPS_AGE_RECIPIENT"`.
6. Upload all resulting files per account to R2 with `aws s3 cp --endpoint-url ...`.
7. Leave `machine-configs.yaml` and `talos-state.yaml` unwritten — layer 03 creates them on first apply.

Exit non-zero if a single Contabo display_name matches multiple live instances
(bug #40 disambiguation), with a message telling the operator to pick one by
numeric ID and re-run.

### `scripts/talos-upgrade.sh`

Purpose: run `talosctl upgrade --preserve` for a single node.

Environment inputs: `NODE`, `TALOSCONFIG`, `IMAGE`, `PRESERVE`,
`STAGE` (optional — for disk-layout changes).

Behavior: invoke `talosctl upgrade --preserve --image=$IMAGE --nodes=$NODE`,
wait for API recovery, re-check the running version via
`talosctl version --nodes=$NODE`, fail non-zero if the post-upgrade version
doesn't match the target.

## Discovery / reuse flow (layers 01 and 02)

```hcl
module "contabo_state" {
  source        = "../../modules/node-state"
  provider_name = "contabo"
  account       = each.key                 # per-account in the accounts for_each
}

locals {
  contabo_existing = {
    for k, _ in module.contabo_state.nodes :
      k => module.contabo_state.state.nodes[k].provider_data.contabo_instance_id
    if try(module.contabo_state.state.nodes[k].provider_data.contabo_instance_id, null) != null
  }
}

import {
  for_each = local.contabo_existing
  to       = module.nodes[each.key].contabo_instance.this
  id       = each.value
}
```

`local.contabo_existing` is fully static at plan time (derived from R2 object
reads), so the import evaluator resolves cleanly — eliminating the
"Configuration for import target does not exist" class of error.

For nodes present in `nodes.yaml` but absent from `state.yaml`, the `import`
block simply does not expand — the resource plans as `+ create`.

After apply, the layer writes `state.yaml` back with observed instance IDs,
IPs, and status.

## Render / apply / upgrade flow (layer 03)

```hcl
# Rendered once per node — exactly the existing configs.tf generators,
# with one rename for clarity.
data "talos_machine_configuration" "rendered" {
  for_each           = local.all_nodes
  cluster_name       = var.cluster_name
  cluster_endpoint   = var.cluster_endpoint
  machine_type       = each.value.role                    # role is already "controlplane" | "worker"
  machine_secrets    = data.terraform_remote_state.secrets.outputs.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches     = local.config_patches_per_node[each.key]
}

locals {
  upgrade_needed = {
    for k, v in local.all_nodes : k => true
    if try(local.upstream_talos_state[k].last_applied_version, "") != "" &&
       local.upstream_talos_state[k].last_applied_version != var.talos_version
  }
}

resource "null_resource" "talos_upgrade" {
  for_each = local.upgrade_needed
  triggers = {
    from_version  = local.upstream_talos_state[each.key].last_applied_version
    to_version    = var.talos_version
    schematic_id  = talos_image_factory_schematic.this.id
  }
  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      NODE        = local.all_nodes[each.key].provider_data.ipv4
      TALOSCONFIG = local_sensitive_file.talosconfig.filename
      IMAGE       = data.talos_image_factory_urls.this.urls.installer
      PRESERVE    = "true"
    }
    command = "${path.root}/../../scripts/talos-upgrade.sh"
  }
}

resource "talos_machine_configuration_apply" "this" {
  for_each                    = local.reachable_nodes
  client_configuration        = data.terraform_remote_state.secrets.outputs.client_configuration
  machine_configuration_input = data.talos_machine_configuration.rendered[each.key].machine_configuration
  node                        = local.all_nodes[each.key].provider_data.ipv4
  depends_on                  = [null_resource.talos_upgrade]
}
```

After apply:
- `machine-configs.yaml` is re-encrypted and written (one file per provider/account).
- `talos-state.yaml` is updated per node with `last_applied_version`,
  `last_applied_at`, `last_applied_run_id`, `config_hash`.

First-apply path (no R2 YAMLs yet): `upstream_talos_state` is empty →
`upgrade_needed` is empty → `talos_machine_configuration_apply` runs fresh →
state files created. Second apply is a clean no-op.

## SOPS validation at plan time

A single fixture committed at `tofu/shared/sops-fixture.age.yaml` encrypts the
literal content `canary: healthy` against every operator's + CI's age
recipient. Every layer that reads or writes an encrypted file includes:

```hcl
data "sops_file" "validation_fixture" {
  source_file = "${path.module}/../../shared/sops-fixture.age.yaml"
}

check "sops_provider_healthy" {
  assert {
    condition     = try(data.sops_file.validation_fixture.data["canary"], null) == "healthy"
    error_message = "SOPS provider cannot decrypt the validation fixture. Check TF_VAR_age_key / SOPS_AGE_KEY env; do not proceed."
  }
}
```

OpenTofu 1.6+ evaluates `check` blocks during both `plan` and `apply`, so a
broken age key fails the plan before any discovery or import runs. Rotating
age recipients requires a one-line fixture update, and CI surfaces the
mismatch immediately.

## Credential flow (replaces the leak)

Before:
- `TF_VAR_contabo_accounts` contains `{"<acct>":{"auth":{"oauth2_*":...},...}}`
  and is dumped by GitHub Actions in every job's `##[endgroup]` env list.

After:
- The Contabo OAuth2 creds live only in `production/inventory/contabo/<acct>/auth.yaml`
  (age-encrypted).
- Layer 01 decrypts them in-process via the SOPS provider and passes them to
  the `contabo` provider alias and to `module.nodes[...].contabo_client_secret`.
- No shell env, no `TF_VAR_*`, no JSON blob. GitHub's env dump shows only the
  age key (already a masked `TF_VAR_age_key`).

For Oracle, the auth flow is unchanged — WIF session tokens minted per-job
from GitHub OIDC — but the non-sensitive pointers move from `TF_VAR_oci_accounts`
to `auth.yaml` for consistency.

For reference: the currently-leaked Contabo credentials must be rotated before
this change lands.

## Bootstrap / migration

CI-automatic variant (default): `tofu-apply.yml` gets a conditional first step
that runs `scripts/seed-inventory.sh` when
`aws s3 ls s3://cluster-tofu-state/production/inventory/` is empty. On every
subsequent run it's a no-op (the tree is already populated). CI has R2 write
access via the state bucket credentials, so no additional secrets are needed.

Migration steps:

1. Merge this spec; operators rotate the leaked Contabo OAuth2 credentials.
2. Merge the `node-state` module, the SOPS fixture, and the two shell scripts
   in a single PR. No behavior change yet.
3. Merge a PR that wires layer 01 to the new module. Keep `imports.tf` as
   fallback. Conditional seed step added to `tofu-apply.yml`.
4. Run `tofu-apply` against main. Seed step populates R2. Layer 01 imports
   existing three CPs, writes `state.yaml`, no resource changes.
5. Merge a PR wiring layer 02-oracle and layer 02-onprem the same way.
6. Merge a PR wiring layer 03 to the new render/upgrade flow.
7. Merge a PR deleting `tofu/layers/01-contabo-infra/imports.tf`,
   `tofu/shared/inventory/*.yaml`, the `TF_VAR_contabo_accounts` wiring in
   `.github/workflows/tofu-layer.yml`, and the equivalent for
   `TF_VAR_oci_accounts` / `TF_VAR_onprem_accounts`.
8. Add a regression check to `tofu-plan.yml` that asserts zero resource diffs
   on a steady-state plan.

Rollback: at every step, reverting the PR restores the previous behavior. The
R2 `inventory/` tree stays around but is simply unread.

## Error handling and idempotency

| Failure | Behavior | Recovery |
|---|---|---|
| SOPS fixture can't decrypt | `check` block fails plan with clear message | Fix age key env, re-run |
| R2 `state.yaml` missing | `yamldecode` of empty string → `{}` → no imports expand → fresh creates | No action; apply writes the file |
| R2 `machine-configs.yaml` missing | Layer 03 renders fresh from secrets + nodes.yaml inputs | No action; apply writes the file |
| Contabo API returns 404 for stored `contabo_instance_id` (instance deleted out-of-band) | `contabo_instance` refresh fails → plan proposes replacement | Operator confirms or restores manually |
| Node in `nodes.yaml` with no `state.yaml` entry | Fresh create | Normal first-apply path |
| `talosctl upgrade` fails mid-flight | `null_resource` errors; `talos-state.yaml` unchanged; next run retries | Operator investigates (talosctl dmesg), re-run apply |
| Duplicate display_name on Contabo side | Not a concern post-bootstrap — we key by instance_id | Seed script disambiguates on first run |
| Age recipient rotation | Fixture decrypt fails on stale keys | Rewrite all encrypted files with new recipient set; rotate fixture last |

Idempotency guarantees:
- `aws_s3_object` writes with identical `content` do not issue PutObject (provider dedupes).
- `yamlencode` over sorted maps is deterministic.
- `null_resource.talos_upgrade` triggers (`from_version`, `to_version`, `schematic_id`) don't change after a successful upgrade — no re-invoke.
- `talos_machine_configuration_apply` is idempotent by design.

Concurrency: backend-level state lock (`use_lockfile = true`, already in use)
serializes concurrent applies of the same layer. File-level ownership (one
writer per key) means layers can apply in parallel without R2 write conflicts.

## Testing plan

Static:
- `tflint` passes (pre-commit).
- `tofu fmt -recursive -check` (pre-commit).
- `tofu validate` in every layer against a golden `testdata/inventory/` tree.

Fixture-based plan tests (new `scripts/test-plan-fixtures.sh`):
- `testdata/inventory-empty/` → expect: all three Contabo resources in `+ create`.
- `testdata/inventory-steady/` → expect: zero resource diffs (proves reuse).
- `testdata/inventory-version-bump/` (`last_applied_version: v1.12.5`, `var.talos_version: v1.12.6`) → expect: `null_resource.talos_upgrade` planned per node; `aws_s3_object.talos_state` in `~ update`.
- `testdata/inventory-missing-machine-configs/` → expect: layer 03 renders, writes `machine-configs.yaml` in `+ create`, `talos_machine_configuration_apply` in `~ update`.
- `testdata/inventory-sops-broken/` → expect: plan fails on `check "sops_provider_healthy"`.

Integration (manual, dev cluster):
- Full reset → apply. Expect: six layers green, R2 inventory tree populated, `talosctl health` reports healthy, kubeconfig pulls cleanly.
- Version bump: change `var.talos_version`, re-apply. Expect: `talosctl upgrade` runs per node, cluster stays up, `talos-state.yaml` reflects the new version.
- Bit-rot drill: delete `state.yaml` in R2, re-apply. Expect: layer re-discovers and re-populates without recreating resources.

CI regression check in `tofu-plan.yml`:
- After a known-good baseline apply, a plan with no input changes must show zero resource diffs. Fail the workflow if any layer proposes a change.

## Open questions

None at authoring time. The two decisions the user deferred to me (CI-automatic
bootstrap; commit to SOPS provider with plan-time validation) are baked into
the spec above.
