# Cluster provision (reproducible path)

Single operator entrypoint: **`cluster-provision`**.

## Modes

| Mode | What it does |
|---|---|
| `full` | preflight → sync-talos-images → tofu-apply → optional wipe → sync-cluster-template → optional flux |
| `infra` | preflight → tofu-apply |
| `cluster` | preflight → optional wipe → sync-cluster-template → optional flux |
| `images` | preflight → sync-talos-images |

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

- New OCI free-tier account: add to `accounts.yaml`, seed inventory with
  `ocpus: 2 / memory_gb: 12 / boot_volume_size_gb: 100`, run
  `cluster-provision` mode=infra (or full).
- Plan-time enforcement lives in `tofu/modules/oracle-account-infra/free-tier.tf`
  and `scripts/lib/oci_free_tier.py`.
