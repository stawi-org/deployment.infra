# Omni takeover — tofu shrinks to provisioner-only

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move cluster lifecycle (Talos config push, bootstrap, upgrades, Flux installation, cluster DNS) from tofu to Omni. Tofu's role compresses to provisioning compute instances. Adding a node = edit `nodes.yaml`; tofu provisions the VM with an Omni-aware Talos image; the VM auto-registers in Omni; an Omni machine class assigns it to a cluster.

**Architecture:** Single source of truth for declared intent is the per-account `nodes.yaml` in R2. Single source of truth for cluster runtime state is Omni. Tofu reads `nodes.yaml` to provision; tofu writes back observed instance IDs / IPs (for the contabo + oracle accounts that have managed instance lifecycle). Talos image variants live in R2 (raw / iso / oracle qcow2 archive); image generation runs in CI against Omni's gRPC factory and updates `tofu/shared/inventory/talos-images.yaml`. Cluster definition lives in Omni's Cluster spec (which includes Flux as a system extension/deployment) and is applied via `omnictl cluster template sync` from a YAML in this repo.

**Tech stack:** Tofu 1.10, Omni v1.7+ (gRPC ManagementService for schematic mint), `omnictl` for cluster-template sync, AWS CLI v2 against R2 + OCI Object Storage, GitHub Actions, the existing CF + Contabo + OCI providers.

**Decisions locked with operator:**
- **Q1 → drop `00-talos-secrets`** entirely. Omni mints its own cluster PKI per cluster.
- **Q2 → drop `04-flux`**. Flux installs as part of Omni's cluster template (Omni v1.7+ supports system extensions and deployments declaratively).
- **Q3 → keep `nodes.yaml` bidirectional**. Operator declares intent; tofu writes back observed IPs / instance IDs. Omni's machine inventory is downstream of `nodes.yaml`, not upstream.
- **Q4 → keep `02-onprem-infra`**. On-prem nodes can take LB role; their public IPs need DNS published.

---

## Task 1 — Schematic source + plan doc (this PR)

**Files:**
- Create: `tofu/shared/schematics/cluster.yaml`
- Create: `docs/superpowers/plans/2026-04-30-omni-takeover.md` (this file)

The new schematic file is the input to Omni's image factory. It deliberately omits `siderolink.api=...` from `extraKernelArgs` because Omni adds those on a per-image basis (so the schematic stays stable across Omni master-key rotations).

The legacy `tofu/shared/schematic.yaml` stays in place until the consumers (`tofu/layers/01-contabo-infra/image.tf`, `tofu/modules/oracle-account-infra/image.tf`) get rewired to consume `talos-images.yaml` in Task 4 / Task 5. Do not delete the old file in this task — it would break tofu plan immediately.

**Verification:** Files exist; `tofu fmt -check tofu/`.

## Task 2 — `regenerate-talos-images.yml`: schematic mint + R2 upload

**Files:**
- Create: `.github/workflows/regenerate-talos-images.yml`
- Create: `scripts/omni-image-factory.sh` — wraps `grpcurl` against Omni's `cosi.runtime.Runtime/Get` + `omni.management.ManagementService/CreateSchematic`
- Create: `tofu/shared/inventory/talos-images.yaml` — empty stub committed at first; CI populates on first run
- Modify: `.github/workflows/tofu-layer.yml` — add `OMNI_SERVICE_ACCOUNT_KEY` to the secrets block (no consumers yet — added so Task 4/5 can read it)

The workflow:
1. Reads `tofu/shared/schematics/cluster.yaml` → SHA256 → if matches the `schematic_id` already in `talos-images.yaml` and `--force` not passed, exits 0.
2. POSTs the customization to Omni's gRPC ManagementService via `omni-image-factory.sh` using the service-account key. Omni returns the `schematic_id`.
3. For each format the providers need (`metal-amd64.raw.zst`, `oracle-amd64.qcow2`, `metal-amd64.iso`), wgets `https://cp.stawi.org/image/<schematic_id>/<talos_version>/<format>` (Omni's image proxy serves variants the factory has cached or will mint on demand).
4. Uploads each to `s3://cluster-tofu-state/production/talos-images/<talos_version>/<schematic_id>/<format>` via `aws s3 cp` (existing R2 creds).
5. Writes the new `talos-images.yaml`:
   ```yaml
   schematic_id: <hash>
   talos_version: v1.13.0
   formats:
     contabo:
       url: https://cluster-tofu-state.<r2-account>.r2.cloudflarestorage.com/production/talos-images/v1.13.0/<id>/metal-amd64.raw.zst
       sha256: <hash>
     onprem:
       url: ... metal-amd64.iso
       sha256: <hash>
     oracle:
       qcow2_url: ... oracle-amd64.qcow2
       qcow2_sha256: <hash>
   ```
6. If the file changed: opens an auto-PR (`bot/talos-images-bump`) — operator reviews + merges. No direct-to-main commit because it changes input that triggers VPS reinstalls.

**Triggers:** `workflow_dispatch` (force flag) + cron `0 6 * * 1` (Mondays — catches new Talos versions).

**Verification:** Manual dispatch produces a PR with non-empty `talos-images.yaml`; CI plan on the PR shows zero diffs (no consumers wired yet).

**Dependency:** operator creates an Omni service account with `Operator` role in the dashboard, exports the key as `OMNI_SERVICE_ACCOUNT_KEY` GitHub secret. One-time setup; document in repo README and in this plan.

## Task 3 — OCI Object Storage upload (parallel job)

**Files:**
- Modify: `.github/workflows/regenerate-talos-images.yml` — add a matrix job `oci-upload` per OCI account
- Modify: `tofu/shared/inventory/talos-images.yaml` — extends `formats.oracle` with `<account>: { ocid: ..., bucket: ..., object: ... }` per OCI account

The job:
1. Pulls qcow2 + manifest.json + image_metadata.json from R2 (already there from Task 2).
2. Bundles into `.oci` archive (existing format the OCI provider expects — see `node-oracle/oci-image-create-or-find.sh` for the layout).
3. Uploads to that OCI account's Object Storage bucket using its WIF profile (already configured in R2 inventory under `oracle/<account>/auth.yaml`).
4. Calls OCI Compute API to import the image as `oci_core_image`; captures the OCID.
5. Writes the OCID + bucket + object key into `talos-images.yaml` under `formats.oracle.<account>`.

**Verification:** Each OCI account ends up with a distinct OCID in `talos-images.yaml`. Manual `oci compute image list` shows the imported image.

## Task 4 — Refactor `node-contabo` to consume images-inventory

**Files:**
- Delete: `tofu/modules/node-contabo/ensure-image.sh`
- Delete: `tofu/layers/01-contabo-infra/image.tf` (the `talos_image_factory_*` machinery + `contabo_image` registration)
- Modify: `tofu/modules/node-contabo/main.tf` — `user_data` is now a small cloud-init that runs `talosctl image install` against the URL from `talos-images.yaml` (or, simpler, the contabo provider supports custom-image-by-URL — verify)
- Modify: `tofu/layers/01-contabo-infra/main.tf` — read `tofu/shared/inventory/talos-images.yaml` via `yamldecode(file(...))`; pass `image_url` + `image_sha256` to `node-contabo` module

If contabo provider supports custom-image-by-URL: Tofu registers the URL once per account → `contabo_instance.image_id = that_image.id`. If not: provision a stock Ubuntu base + cloud-init that wgets the .raw.zst, decompresses, dd's onto disk, reboots — but this is a non-trivial bootstrap path; prefer the URL-as-image-id approach if it exists.

**Verification:** `tofu plan 01-contabo-infra` shows zero diffs; a fresh apply provisions a node that boots into Talos with SideroLink → appears in Omni machine inventory within 5 min.

## Task 5 — Refactor `node-oracle` to consume images-inventory

**Files:**
- Delete: `tofu/modules/node-oracle/oci-image-create-or-find.sh` and the `data.external` glue
- Delete: `tofu/modules/oracle-account-infra/image.tf`
- Modify: `tofu/layers/02-oracle-infra/main.tf` — read OCID for this account from `talos-images.yaml`; pass to `oci_core_instance.this.source_details.source_id`

**Verification:** `tofu plan 02-oracle-infra` shows zero diffs across all four accounts; fresh apply on `ambetera` or another untouched account provisions a node that registers in Omni.

## Task 6 — Drop `03-talos` cluster bootstrap machinery

**Files:**
- Delete: `tofu/layers/03-talos/apply.tf`, `bootstrap.tf`, `configs.tf`
- Delete (after Task 11 confirms no readers remain): the `cluster_dns` module's `cp_label-N` records — but keep `prod_label` for LB routing
- Modify: `tofu/layers/03-talos/dns.tf` → reduce to `prod.<zone>` only (the LB record set; keep on-prem-LB-public-IP-routable behaviour from Q4)
- Modify: `tofu/layers/03-talos/outputs.tf` → drop kubeconfig, talosconfig, endpoints; the layer becomes "publish DNS for LB-labelled nodes"
- Rename: `tofu/layers/03-talos/` → `tofu/layers/03-cluster-dns/` (the layer is now ONLY about DNS for LB-labelled nodes; the cluster name is misleading)

**Verification:** `tofu plan 03-cluster-dns` shows destroy of all `cp/cp-N` records + creates of `prod` records (only if any LB-labelled nodes exist); zero changes if no LB nodes are configured.

## Task 7 — Drop `00-talos-secrets`

**Files:**
- Delete: `tofu/layers/00-talos-secrets/` directory
- Delete: any `terraform_remote_state.secrets` references in remaining layers (search-and-destroy)
- Modify: `.github/workflows/tofu-layer.yml` — remove the `secrets` job and the dependent edges in `tofu-plan.yml` / `tofu-apply.yml`

**Verification:** `tofu plan` clean across all surviving layers.

## Task 8 — Drop `04-flux`

**Files:**
- Delete: `tofu/layers/04-flux/` directory
- Delete: `.github/workflows/dispatch-kubeconfig.yml` (no kubeconfig consumer)
- Create: `tofu/shared/clusters/main.yaml` — Omni Cluster spec for the `main` cluster, including:
  - `kubernetesVersion`, `talosVersion`
  - `controlPlanes` + `workers` with machine-class selectors
  - `extensions` block declaring Flux + its config (GitRepository pointing at this repo's `manifests/`, SOPS age secret reference, GitHub App auth reference)
- Create: `.github/workflows/sync-cluster-template.yml` — runs `omnictl cluster template sync` against the spec when the file changes (or on dispatch); creates the cluster on first run, updates on subsequent

**Verification:** First sync creates the cluster in Omni; provisioned machines auto-assign; Flux comes up inside; `kubectl get pods -n flux-system` (via Omni's k8s-proxy) shows source-controller / kustomize-controller running.

## Task 9 — Keep `nodes-writer` modules (Q3 = b)

No action needed in this PR. The bidirectional `nodes.yaml` flow stays as today: operator edits → tofu provisions → tofu writes back observed state. Omni reads from its own machine inventory, not from `nodes.yaml`.

## Task 10 — Drop dependent workflows

**Files to delete:**
- `.github/workflows/cluster-reset.yml`
- `.github/workflows/cluster-reinstall.yml`
- `.github/workflows/cluster-health.yml`
- `.github/workflows/node-recovery.yml`
- `.github/workflows/recover-talos-bootstrap.yml`
- `.github/workflows/talos-diagnose.yml`
- `.github/workflows/publish-talos-configs.yml`
- `.github/workflows/prune-stale-oci-ocids.yml`
- `.github/workflows/cluster-prune-nodes.yml`
- `.github/workflows/reset-cluster-dns.yml`

**Verification:** No workflow file references any of these reusable workflows; Actions tab clean.

## Task 11 — Reconstruction mechanism cleanup

**Files:**
- Delete: `.github/reconstruction/` directory (the YAML files declaring per-node reinstall intent)
- Delete: `.github/workflows/tofu-reconstruct.yml` if it exists
- Delete: `terraform_data` "image_reinstall_marker" / "cluster_wide_reinstall_marker" resources in `01-contabo-infra` / `02-oracle-infra`
- Modify: documentation explaining the new workflow — "to reinstall a node, deassign in Omni dashboard + reset the disk; or `omnictl machine destroy` and let tofu re-provision on next apply"

**Verification:** Grep for `reconstruction` / `reinstall_generation` / `reinstall_marker` returns zero results across `tofu/` and `.github/`.

---

## Execution flow

Each task is its own PR. Each PR includes a focused commit, the relevant test (`bats` for cloud-init renders, `tofu validate` for layer changes, `tofu plan` for end-to-end), and a description that links to this plan and references the operator decisions.

Tasks 1-3 are additive and land first (no destruction of working code). Tasks 4-5 swap consumers (still no deletion of upstream). Tasks 6-11 do the deletions in dependency order — `03-talos` reduced first, then `00-talos-secrets`, then `04-flux`, then dependent workflows, then reconstruction.

After Task 11 the repo is in steady state: tofu only provisions, Omni runs everything else, regenerating images is one workflow, adding a node is one YAML edit.
