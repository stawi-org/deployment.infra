# Cluster provision (reproducible path)

Single operator entrypoint: **`cluster-provision`**.

Desired infrastructure state is **OpenTofu** (inventory + modules). Workflows
orchestrate apply and the rare Omni image build — they do not re-implement
capacity policy in ad-hoc scripts.

## Modes

| Mode | What it does |
|---|---|
| `full` | preflight → sync-talos-images (idempotent) → tofu-apply → optional wipe → sync-cluster-template → optional flux |
| `infra` | preflight → tofu-apply (**day-2** add/remove/resize nodes) |
| `cluster` | preflight → optional wipe → sync-cluster-template → optional flux |
| `images` | preflight → sync-talos-images only |

## Images vs nodes

| Artifact | Built by | Consumed by |
|---|---|---|
| Omni-aware media in R2 | `sync-talos-images` / `omnictl` | Per-cloud import |
| GCE custom image / family `stawi-talos` | import step (reuse if name exists) | OpenTofu `node-gcp` |
| Node count / shape | R2 inventory **or** OpenTofu defaults | `02-*-infra` modules |

- **New nodes** boot the current resolved image.
- **Existing nodes** do not reimage when the catalog changes (GCP/OCI
  `ignore_changes` on boot disks). Upgrade Talos via Omni in place.
- **GCP empty inventory** → module seeds two Spot `e2-medium` workers and
  writes them to R2 on apply (no Python seed job).

```bash
# Day-2 scale / repair
gh workflow run cluster-provision.yml -f mode=infra

# First bring-up or new cloud account
gh workflow run cluster-provision.yml -f mode=full -f deploy_flux=true

# Force image rebuild (rare)
gh workflow run cluster-provision.yml -f mode=images -f force_image_sync=true
```

## Preflight gates

- Omni auth works (`omnictl get user`)
- Required secrets non-empty
- **OCI inventory fits Always Free** (2 OCPU / 12 GB / ≤200 GB boot / ≤2 A1 VMs)

If free-tier validation fails, reconcile first:

```bash
gh workflow run reconcile-oci-free-tier.yml -f write=true -f confirm=RECONCILE
```

## Clean slate

```bash
# 1. Wipe Omni cluster + R2 per-node patches
gh workflow run cluster-clean-slate.yml -f confirm=CLEAN-SLATE -f clear_oci_images=true

# 2. Clear OCI custom-image buckets (separate OIDC matrix)
gh workflow run clear-oci-image-buckets.yml -f confirm=DELETE

# 3. Reconcile free-tier inventory (if not already)
gh workflow run reconcile-oci-free-tier.yml -f write=true -f confirm=RECONCILE

# 4. Full rebuild with current versions.auto.tfvars.json pin
gh workflow run cluster-provision.yml \
  -f mode=full \
  -f force_image_sync=true \
  -f wipe_cluster=false \
  -f deploy_flux=true
```

Node disk wipe (Contabo PUT-reinstall / OCI destroy+create) still requires
bumping `force_reinstall_generation` in the relevant layer `terraform.tfvars`
and pushing, or an image OCID change from step 4.

## Talos version bumps

1. Edit `tofu/shared/versions.auto.tfvars.json` (`talos_version`)
2. Keep `tofu/shared/clusters/main.yaml` talos version in lock-step
3. Merge → `cluster-provision` mode=full with `force_image_sync=true`

## Extensibility

- New OCI account: add to `accounts.yaml`, seed inventory with
  worker `ocpus: 2 / memory_gb: 12 / boot_volume_size_gb: 196` (or run
  `ensure-oci-free-tier-capacity`), then `cluster-provision` mode=infra (or full).
- Plan-time enforcement lives in `tofu/modules/oracle-account-infra/free-tier.tf`
  and `scripts/lib/oci_free_tier.py` (solo 2/12 or two 1/6; boot ≤196).
- **New GCP project:** `scripts/bootstrap-gcp-wif.sh --project …` then merge
  onboard PR. OpenTofu applies default Spot pack; see [docs/gcp-onboard.md](gcp-onboard.md).
