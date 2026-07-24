# Omni host backups on R2 (`cluster-tofu-state`)

## Canonical layout

| Path | Purpose |
|------|---------|
| `production/omni-backups/omni-YYYYMMDDTHHMMSSZ.tar.gz` | **Stable** hourly Omni host snapshots (`/var/lib/omni` + WG + LE) |
| `production/inventory/` | Node inventory + `talos-images.yaml` pointer (small) |
| `production/*.tfstate` | OpenTofu state (small) |

Do **not** date-stamp cutovers into the backup prefix (e.g.
`production/omni-backups-2026-05-24-contabo/`). That pattern left multi‑GB
orphan trees after host moves.

Install media for Talos lives in **`cluster-image-registry`** (and per‑provider
buckets), not under `production/talos-images/` in the state bucket.

## Retention

1. **On-host** (`omni-backup.sh`): after each hourly upload, deletes objects
   whose embedded UTC timestamp is older than `OMNI_BACKUP_RETAIN_DAYS`
   (default **7**).
2. **CI** (`.github/workflows/prune-r2-cluster-state.yml`): daily +
   `workflow_dispatch` — migrate cutovers → stable, age-prune, optional
   **daily collapse** (`retain_mode=daily`, default: one snapshot per UTC
   day for `retain_days`), delete stale cutover trees, delete legacy
   `production/talos-images/`, try R2 lifecycle upsert.
3. **R2 lifecycle** (best-effort via S3 API): expire
   `production/omni-backups/*` after **retain_days + 1**, cutover prefixes
   after **2** days. S3 tokens often lack this permission — CI prune still
   enforces retention.

## Operator commands

```bash
# Dry-run
gh workflow run prune-r2-cluster-state.yml -f dry_run=true -f retain_days=7

# Apply (migrate, prune, delete cutovers + talos-images, lifecycle)
gh workflow run prune-r2-cluster-state.yml -f dry_run=false -f retain_days=7

# Size check
gh workflow run dump-r2-sizes.yml
```

## Live host note

Changing `r2_backup_prefix` in `00-omni-server` only rewrites cloud-init for
the **next** Contabo reinstall (`force_reinstall_generation` / image change).
Until then the host may still upload under an old cutover path; the prune
workflow migrates those objects into `production/omni-backups/` so restore
still works after a reinstall that uses the stable prefix.
