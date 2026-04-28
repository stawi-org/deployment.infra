# Migration: 02-oracle-infra to per-account state files

## Why

Before this change, every oracle account (bwire, brianelvis33, alimbacho67,
ambetera, ...) shared a single tfstate at
`production/02-oracle-infra.tfstate`. A single account's apply failure (OCI
Out-of-Host-Capacity, missing IAM policy, expired session token, tenancy
outage) failed the whole layer apply and blocked downstream layers.

The new shape:

- Each account owns its own state file at
  `production/02-oracle-infra-<account>.tfstate`.
- `backend.tf` is a partial backend; the workflow supplies `key=...` via
  `tofu init -backend-config=...`.
- The layer reads `var.account_key` and scopes its `for_each` blocks to
  `[var.account_key]`.
- `.github/workflows/tofu-apply.yml` runs the layer as a `fail-fast: false`
  matrix over `tofu/shared/accounts.yaml`'s oracle list.
- `tofu/layers/03-talos/main.tf` reads each oracle account's tfstate via
  `for_each` and merges their `nodes` outputs into the single map layer 03
  expects.

End result: a single account's apply failure no longer cancels its siblings
or blocks layer 03/04.

## One-time migration procedure

This is a state-relocation, not a destroy/create. OCI resources stay in
place; only state file paths change. Run once after merging the per-account
PR.

For each `acct` in `tofu/shared/accounts.yaml`'s `oracle:` list (currently
bwire, brianelvis33, alimbacho67, ambetera):

1. Dispatch `tofu-apply` (or run an equivalent local `tofu init` in
   `tofu/layers/02-oracle-infra/`):

   ```sh
   cd tofu/layers/02-oracle-infra
   tofu init -reconfigure \
     -backend-config="key=production/02-oracle-infra-${acct}.tfstate" \
     -backend-config="endpoints={s3=\"https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com\"}"
   tofu apply -var "account_key=${acct}"
   ```

2. The first apply on an empty per-account state file lets the
   `import { for_each = ... }` blocks in `imports.tf` adopt the live OCI
   instances, bastion, and image bucket from the existing API objects.
   Plan should show only imports plus possibly some neutral metadata
   updates — no destroy/create.

3. Repeat for every oracle account.

The CI matrix in `tofu-apply.yml` does this naturally on the first run after
merge: each matrix cell calls `tofu init` with its own `-backend-config="key=..."`,
finds an empty state, and the imports adopt the in-tenancy resources.

## Cleanup

After all per-account state files exist in R2 and have applied cleanly,
the legacy `production/02-oracle-infra.tfstate` is obsolete. Keep it for one
release as a rollback safety net, then delete via:

```sh
aws s3 rm "s3://cluster-tofu-state/production/02-oracle-infra.tfstate" \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
aws s3 rm "s3://cluster-tofu-state/production/02-oracle-infra.tfstate.backup" \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
```

`cluster-reset.yml`'s `wipe-state` step already deletes the legacy path
defensively, so a future reset run also covers this.

## Rollback

If a per-account state file gets into a bad shape, the legacy
`production/02-oracle-infra.tfstate` (kept as a backup) can be restored by
reverting the layer 02 `backend.tf` + `main.tf` + `variables.tf` changes,
re-pointing `tofu init` at the single key, and rerunning apply. As long as
the cleanup step above hasn't fired, the legacy state is intact.
