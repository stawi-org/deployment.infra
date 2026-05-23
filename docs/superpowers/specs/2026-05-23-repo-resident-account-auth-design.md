# Repo-Resident Account Auth + Self-PR Bootstrap

**Date:** 2026-05-23
**Author:** Peter Bwire (bwire517@gmail.com)
**Status:** Design — awaiting operator review

## Problem

Onboarding a new cloud account today is a multi-surface ritual:

1. Operator runs `scripts/bootstrap-oci-oidc.sh` against the new OCI tenancy. Script prints a YAML stanza to stdout.
2. Operator hand-edits `tofu/shared/accounts.yaml`, commits, opens a PR.
3. Operator base64-encodes the auth payload and triggers `upload-inventory.yml` to push it to R2.
4. Operator triggers `upload-inventory.yml` again for `nodes.yaml`.
5. Operator triggers `sync-talos-images.yml`; the resulting bot PR adds the per-tenancy image OCID.

The auth values themselves (tenancy OCID, OIDC client id+secret, IDCS domain URL, compartment, region, VCN CIDR) end up scattered across:

- The OCI Identity Domain console (source of truth for what was created).
- `s3://cluster-tofu-state/production/inventory/<provider>/<account>/auth.yaml` (consumed by tofu).
- The operator's terminal scrollback (the script printed it once).

When the operator later needs to recover or audit those values, they have to dig. Adding a node to an existing tenancy is fine (R2-only edit), but onboarding remains a manual chain that's easy to half-finish.

## Goal

One operator command — `bootstrap-oci-oidc.sh` — leaves a reviewable PR on this repo containing everything the deployment needs to apply the new account. Auth credentials live in the repo (SOPS-encrypted) so they're discoverable next to the code, not scattered across R2 + tenancy consoles. The R2 inventory becomes purely dynamic state (per-node specs, observed Talos configs, image catalog).

## Non-Goals

- Not changing how individual node configs are managed. `production/inventory/<provider>/<account>/nodes.yaml` stays in R2 and remains operator-mutable via `upload-inventory.yml`.
- Not introducing a new Kubernetes Secret store, External Secrets controller, or in-cluster auth surface. "Auth in the repo" is the boundary; flux/k8s consumers are not in scope.
- Not designing a GitHub App or PAT-based auth path for the script. The script uses plain `git push` and prints the GitHub "compare & PR" URL — operator clicks it once.
- Not splitting nodes.yaml into "declarative spec" + "observed state" tracks. Out of scope; today's "tofu writes back to nodes.yaml" pattern stays.

## End-State Architecture

### Repo: static declarative inputs

```
tofu/shared/
├── accounts.yaml                          (existing — provider → account-name lists)
└── accounts/                              (NEW — per-account credentials, SOPS-encrypted)
    ├── contabo/bwire/auth.yaml
    ├── oracle/bwire/auth.yaml
    ├── oracle/brianelvis33/auth.yaml
    ├── oracle/alimbacho67/auth.yaml
    ├── oracle/ambetera/auth.yaml
    ├── oracle/anto/auth.yaml
    ├── oracle/allanofwiti/auth.yaml
    └── oracle/madiang100/auth.yaml
```

`tofu/shared/inventory/` is removed from the repo entirely; the term "inventory" only refers to R2 going forward.

### R2: dynamic state

```
s3://cluster-tofu-state/production/inventory/
├── talos-images.yaml                      (MOVED from repo)
├── <provider>/<account>/nodes.yaml
└── <provider>/<account>/<talos-version>/<node>.yaml
```

### `.sops.yaml` (new, repo root)

```yaml
creation_rules:
  - path_regex: tofu/shared/accounts/.*/auth\.yaml$
    encrypted_regex: '^(.*)$'
    age: <list-from-SOPS_AGE_RECIPIENTS-var>
```

Encryption rule applies to every file under `tofu/shared/accounts/*/*/auth.yaml`. Operators run `sops -e -i <file>` and `sops -d <file>` without flags. CI decrypts via the existing `SOPS_AGE_KEY` secret.

### auth.yaml schema

Unchanged from today. Outer `auth:` key wrapping a flat dict of credentials and per-account infra knobs. The single hosted shape works for both contabo and oracle (onprem has no auth file).

```yaml
auth:
  tenancy_ocid: ocid1.tenancy.oc1..…           # oracle
  region: eu-marseille-1                        # oracle
  compartment_ocid: ocid1.tenancy.oc1..…        # oracle
  vcn_cidr: 10.200.0.0/16                       # oracle
  enable_ipv6: true                             # oracle
  auth_method: SecurityToken                    # oracle
  domain_base_url: https://idcs-….oraclecloud.com  # oracle
  oidc_client_identifier: "<clientId>:<clientSecret>"  # oracle
  # contabo fields (OAuth2 client_id, client_secret, ...) per existing schema
```

## Component Changes

### 1. `tofu/modules/node-state` — read path flip, no more auth writes

- `auth_local` becomes `${path.module}/../../shared/accounts/<provider>/<account>/auth.yaml` (resolved at module load via `var.provider_name` + `var.account`).
- Remove `is_encrypted_auth` provider switch. Every provider's auth is SOPS-encrypted now; the existing `data "sops_file"` block applies uniformly.
- Delete `aws_s3_object.auth` and `aws_s3_object.auth_plaintext` resources.
- Delete `write_auth`, `auth_content`, `age_recipients` input variables.
- `nodes.yaml` read path and `aws_s3_object.nodes` write resource unchanged.
- `per_node_configs` write logic unchanged.

### 2. Layer wirings (`01-contabo-infra`, `02-oracle-infra`, `03-onprem-infra`)

- Drop the `write_auth = true` + `auth_content = {...}` arguments on `module.<provider>_account_state`.
- All other layer behavior unchanged.

### 3. `talos-images.yaml` reader

- Every tofu reference currently pointing at `${path.module}/../../shared/inventory/talos-images.yaml` is repointed at `${var.local_inventory_dir}/talos-images.yaml`.
- `talos-images.yaml` is uploaded under `s3://cluster-tofu-state/production/inventory/talos-images.yaml`; the existing pre-plan `aws s3 sync s3://cluster-tofu-state/production/inventory/ /tmp/inventory/` step already grabs it.

### 4. `.github/workflows/sync-talos-images.yml`

- Rename the `assemble-and-pr` job to `assemble-and-upload`.
- Replace the bot-PR rendering and `gh pr create` steps with an `aws s3 cp` to the R2 path above.
- Drop the `pull-requests: write` permission and the PR body templating.
- Workflow inputs and the `oci-import` / `discover-oracle` jobs are unchanged.

### 5. `.github/workflows/upload-inventory.yml`

- Drop `auth.yaml` from the `filename` choice list (only `nodes.yaml` remains).
- Drop the contabo SOPS-encrypt branch (no longer needed since auth never touches this workflow).
- The workflow may be renamed `upload-nodes.yml` in a follow-up; out of scope for the migration PRs.

### 6. `scripts/bootstrap-oci-oidc.sh` — PR-emitting tail

After the existing OCI provisioning succeeds (sections 1–8 in the current script — unchanged), the script appends:

1. Resolve repo path:
   - `--repo-path PATH` flag (explicit override), or
   - `git rev-parse --show-toplevel` from `cwd`.
   - Fail fast if no `.sops.yaml` is found in the resolved root (sanity check that we're in the right repo).
2. Build the auth body as plain YAML.
3. Write to `<repo>/tofu/shared/accounts/<provider>/<gh_profile>/auth.yaml`.
4. `sops -e -i <file>` — encrypts in place via the `.sops.yaml` rule.
5. Edit `tofu/shared/accounts.yaml` to append the new account name under the provider's list (idempotent — no-op if already present). YAML edit is line-based to preserve comments.
6. `git checkout -b onboard-<provider>-<gh_profile>` from the current `main` (refuses if the branch already exists locally; operator can override with `--branch NAME`).
7. `git add <auth.yaml> <accounts.yaml>` + `git commit -m "onboard <provider> <gh_profile>: add to accounts.yaml + encrypted auth"`.
8. `git push -u origin <branch>` unless `--no-push`. Capture the "Create a pull request" URL git prints on stderr; print a clean final banner: `OPEN: <url>`.

New tool requirements: `git`, `sops` (both fail-fast if missing). No `gh` CLI. No GitHub token.

New flags:
- `--repo-path PATH` — default: `git rev-parse --show-toplevel`.
- `--branch NAME` — default: `onboard-<provider>-<gh_profile>`.
- `--no-push` — write + commit locally only, for operator inspection.

Removed: the trailing "Rendered OCI inventory stanza" stdout block (the YAML is now committed instead of printed).

The `--repo` and `--branch` flags currently used to target the repo URL string for the inventory stanza header become unused; remove them.

## Migration

Three ordered PRs. M1 is a pure no-op for the running fleet; M2 is the operational cutover; M3 is opt-in cleanup.

### PR M1 — Seed encrypted auth into the repo

- Add `.sops.yaml` at repo root (the rule above).
- Add `scripts/migrate-auth-to-repo.sh` (one-shot, intended to be deleted after M1 lands):
  - For each provider/account in `tofu/shared/accounts.yaml`:
    - `aws s3 cp s3://cluster-tofu-state/production/inventory/<provider>/<account>/auth.yaml /tmp/...`.
    - If contabo: `sops -d` to plaintext.
    - If oracle: already plaintext.
    - If onprem: no auth file; skip.
    - Write `tofu/shared/accounts/<provider>/<account>/auth.yaml` and `sops -e -i` it.
  - Commit on a feature branch and open a PR for review.
- Tofu module is unchanged in this PR — fleet still reads from R2. The new repo files exist but nothing consumes them yet.

### PR M2 — Flip read path; collapse old plumbing

All the code/workflow changes in Components 1–5 above land in a single PR:

- Tofu module flip (read from repo, drop auth writers).
- Layer drops of `write_auth` calls.
- `talos-images.yaml` reader repointed to R2 staging dir; corresponding file uploaded to R2 as part of the PR's CI workflow (so the read path is non-empty when tofu plans).
- `sync-talos-images.yml` updated to `assemble-and-upload`.
- `upload-inventory.yml` slimmed to nodes-only.

This PR's tofu plan should be no-op for fleet resources (auth content is identical, just sourced from a different path).

### PR M3 — Optional cleanup

- New workflow `cleanup-r2-auth.yml` (workflow_dispatch). Deletes every `production/inventory/<provider>/<account>/auth.yaml` object from R2.
- Run only after a few clean tofu-apply cycles confirm M2 is healthy.
- Once run, also delete `migrate-auth-to-repo.sh` from the repo.

## Operational Flow After Migration

**Onboarding a new OCI account:**

1. Operator runs `scripts/bootstrap-oci-oidc.sh --profile <PROF> --gh-profile <SLUG> [--repo-path <PATH>]` from a clean checkout of `main`.
2. Script provisions OCI identity domain + budget (unchanged).
3. Script writes encrypted `auth.yaml`, edits `accounts.yaml`, commits, pushes, prints PR URL.
4. Operator opens the printed URL, reviews, merges.
5. Operator triggers `sync-talos-images.yml` (or waits for weekly cron). Talos image is imported into the new tenancy; `talos-images.yaml` in R2 is updated. No PR opens.
6. Operator triggers `upload-inventory.yml` for `nodes.yaml` if they want a node from day one.
7. Operator triggers `tofu-apply`. VCN, subnet, instance, DNS as appropriate.

**Recovering auth values:**

`sops -d tofu/shared/accounts/<provider>/<account>/auth.yaml` from any checkout. No R2 round-trip, no console digging.

**Adding a node to an existing account:** unchanged — `upload-inventory.yml` workflow with `filename=nodes.yaml`.

## Risks and Tradeoffs

- **Trust boundary on repo write.** Operators who can push to `main` now hold the lever for OCI/Contabo creds, not just code. This was already mostly true (contabo auth was SOPS-encrypted in R2 with the same age key), but the merge gate moves from "R2 bucket write access" to "repo merge access." Concretely: anyone who can land a PR can rotate or substitute auth — no more separate R2-bucket-write capability is needed. Branch protection on `main` is the only enforcement.
- **SOPS local tooling required for the script.** Operator machines now need `sops` installed alongside `oci`, `jq`, `git`. This is a single static binary download; acceptable.
- **Migration sequencing.** M1 must land before M2 or tofu plans break (M2 expects encrypted files to already exist in the repo). PRs are ordered explicitly; no automation enforces ordering — operator responsibility.
- **`sync-talos-images` loses its merge gate.** Previously the bot PR let operators eyeball schematic-SHA changes before they hit the fleet. After M2, sync runs write straight to R2 and the next tofu-apply picks up the new OCID. Mitigation: existing OCI instances are protected by `lifecycle.ignore_changes = [source_details]` (per fix #aa721d1), so an unreviewed OCID rotation only affects fresh boots. If a review gate is desired in the future, it can be added back as a separate audit dashboard or by writing the file to a staging R2 path that requires manual promotion.
- **`.sops.yaml` age recipients drift from `vars.SOPS_AGE_RECIPIENTS`.** The repo file is the authoritative recipient list for SOPS operations; the GH var must stay in sync (workflows that programmatically encrypt — only `migrate-auth-to-repo.sh` — read from the var, but anything that DECRYPTS uses the file). Add a CI check that compares the two and fails on mismatch.

## Testing

- **PR M1:** Smoke test by running `sops -d` on each new file under `tofu/shared/accounts/`; output must match the corresponding R2 plaintext byte-for-byte (for oracle) or post-decryption (for contabo).
- **PR M2:** `tofu plan` on every layer (matrix in `tofu-plan.yml`) must be no-op. Specifically, `02-oracle-infra` for each account must show zero resource changes when the encrypted auth matches the prior R2 plaintext.
- **Bootstrap script:** integration-test on a throwaway OCI tenancy. Verify (a) the encrypted file is decryptable, (b) `accounts.yaml` edit lands correctly, (c) the branch pushes, (d) a tofu plan against the new account succeeds.
- **`sync-talos-images.yml`:** trigger manually after M2; confirm `talos-images.yaml` lands in R2 at the expected path and a follow-up tofu plan reads the new OCID.

## Open Questions

- Should `upload-inventory.yml` be renamed `upload-nodes.yml` post-M2 to reflect its narrowed scope? (Cosmetic; deferred.)
- Should `.sops.yaml` enforce different recipient sets per provider (e.g. tighter access for contabo OAuth secrets)? Today every secret uses the same age recipients; tightening is possible later via additional `creation_rules` blocks but not required for the migration.
