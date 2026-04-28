# Migration: per-account state files for 01-contabo, 02-oracle, 02-onprem

## Why

Before this change, each provider's tofu layer used a single tfstate file
shared across all accounts in `tofu/shared/accounts.yaml`:

- `production/01-contabo-infra.tfstate`
- `production/02-oracle-infra.tfstate` (consolidated first; per-account split shipped at commit 7448b85)
- `production/02-onprem-infra.tfstate`

A single account's apply failure (Contabo OAuth blip, OCI Out-of-Host-Capacity,
missing IAM policy, expired session token, tenancy outage, R2 sync hiccup,
nodes.yaml decryption issue) failed the whole layer apply and blocked
downstream layers — even when the other accounts in that layer were
perfectly healthy.

The new shape (uniform across all three providers):

- Each account owns its own state file at
  `production/<layer>-<account>.tfstate`.
- Each layer's `backend.tf` is a partial backend; the workflow supplies
  `key=...` via `tofu init -backend-config=...`.
- Each layer reads `var.account_key` (validated against the matching
  list in `tofu/shared/accounts.yaml`) and scopes its `for_each` blocks
  to `[var.account_key]`.
- `.github/workflows/tofu-apply.yml` and `tofu-plan.yml` run each layer
  as a `fail-fast: false` matrix over the corresponding accounts.yaml list.
- `tofu/layers/03-talos/main.tf` reads each account's tfstate via
  `for_each` and merges per-account `nodes` outputs into the single map
  layer 03 expects. Contabo's `cluster_reinstall_marker` (now a per-account
  output) is folded across accounts via lex-largest hash so a scope=all
  reinstall on any contabo account still re-fires the bootstrap RPC.
- The talos `if:` gate uses `result != 'cancelled'` rather than
  `result == 'success'`, so per-cell failures don't block the cluster.
  Quorum problems are caught downstream by the cluster-health step.

End result: a single account's apply failure no longer cancels its siblings
or blocks layer 03/04.

## One-time migration procedure

This is a state-relocation, not a destroy/create. Cloud resources stay in
place; only state file paths change. Run once per `(layer, acct)` pair
after merging the per-account PR.

For each `(layer, acct)` pair from `tofu/shared/accounts.yaml`:

| layer              | accounts                                    |
|--------------------|---------------------------------------------|
| 01-contabo-infra   | bwire                                       |
| 02-oracle-infra    | bwire, brianelvis33, alimbacho67, ambetera  |
| 02-onprem-infra    | tindase                                     |

1. Dispatch `tofu-apply` (or run an equivalent local `tofu init` in
   `tofu/layers/<layer>/`):

   ```sh
   cd tofu/layers/<layer>
   tofu init -reconfigure \
     -backend-config="key=production/<layer>-${acct}.tfstate" \
     -backend-config="endpoints={s3=\"https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com\"}"
   tofu apply -var "account_key=${acct}"
   ```

2. The first apply on an empty per-account state file lets the
   `import { for_each = ... }` blocks adopt the live cloud-side resources.
   Plan should show only imports plus possibly some neutral metadata
   updates — no destroy/create.

3. Repeat for every `(layer, acct)` pair.

The CI matrix in `tofu-apply.yml` does this naturally on the first run after
merge: each matrix cell calls `tofu init` with its own `-backend-config="key=..."`,
finds an empty state, and the imports adopt the in-tenancy resources.

### Per-layer notes

- **01-contabo-infra**: `imports.tf` already has an
  `import { for_each = local.contabo_existing_instance_ids }` block,
  sourced from both the operator-written
  `shared/bootstrap/contabo-instance-ids.yaml` and the per-account
  `nodes.yaml`'s `provider_data.contabo_instance_id`. Once the
  per-account state's matrix cell runs its first apply with a
  populated bootstrap fallback, the existing instances are adopted by
  the import — no destroy/create.
- **02-oracle-infra**: `imports.tf` defensively lists live OCI
  instances, bastions, and image buckets and only imports objects that
  still exist in the API. No-op-on-import.
- **02-onprem-infra**: no cloud resources, no `imports.tf`. The
  state-relocation is just the `module.onprem_account_state[<acct>]`
  and `module.onprem_nodes_writer[<acct>]` entries — they re-read the
  same `nodes.yaml` content on first apply, so the new state file
  reaches the same shape as the old one.

## Cleanup

After all per-account state files exist in R2 and have applied cleanly,
the legacy single-key tfstate paths are obsolete. Keep them for one
release as a rollback safety net, then delete via:

```sh
for LAYER in 01-contabo-infra 02-oracle-infra 02-onprem-infra ; do
  for SUFFIX in "" .backup ; do
    aws s3 rm "s3://cluster-tofu-state/production/${LAYER}.tfstate${SUFFIX}" \
      --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
      --region us-east-1 || true
  done
done
```

`cluster-reset.yml`'s `wipe-state` step already deletes the legacy paths
defensively, so a future reset run also covers this.

## Rollback

If a per-account state file gets into a bad shape, the legacy single-key
tfstate (kept as a backup) can be restored by reverting the layer's
`backend.tf` + `main.tf` + `variables.tf` changes, re-pointing `tofu init`
at the single key, and rerunning apply. As long as the cleanup step above
hasn't fired, the legacy state is intact.
