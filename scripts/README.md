# scripts/

Operator + workflow tooling. Each script prints usage with `-h`/`--help` or
empty args. Most are invoked from `.github/workflows/`; a few are operator-
run during account onboarding.

## Operator-run

| Script | Purpose |
|---|---|
| `bootstrap-oci-oidc.sh` | Idempotently set up an OCI Identity Domain so GitHub Actions can WIF-federate into a new tenancy. Non-interactive: worktree off `origin/main`, encrypted `auth.yaml` + `accounts.yaml`, push + REST PR (`GITHUB_TOKEN`, no `gh` CLI). After merge, `onboard-oracle.yml` seeds free-tier nodes and runs `cluster-provision`. Usually run from OCI Cloud Shell. |
| `bootstrap-gcp-wif.sh` | **Once per GCP project:** WIF + SA + SOPS auth + accounts.yaml PR. Capacity defaults live in OpenTofu, not here. |
| `seed-inventory.sh` | Append a new account stanza to the R2-backed inventory used by tofu's `node-state` module. |

## Workflow-invoked (don't run by hand)

| Script | Invoked by |
|---|---|
| `cluster-health.sh` | `cluster-health.yml` |
| `configure-oci-wif.sh` | `tofu-layer.yml` (OCI auth step) |
| `build-oci-auth-json.py` | `tofu-layer.yml` |
| `stage-oracle-auth-from-repo.sh` | `tofu-layer.yml`, `sync-talos-images.yml` (decrypt repo OCI auth for WIF / image import) |
| `stage-gcp-auth-from-repo.sh` | `tofu-layer.yml`, `sync-talos-images.yml` (decrypt repo GCP auth for WIF ADC) |
| `prune-stale-oci-instance-ocids.sh` + `.py` | `prune-stale-oci-ocids.yml` |
| `rename-inventory-accounts.sh` + `rename_inventory_keys.py` + `rename-inventory-keys.sh` | `rename-inventory-{accounts,keys}.yml` |
| `sync-sops-check.sh` + `check-sops-check-drift.sh` | pre-commit hooks |

## Shared library

| Module | Purpose |
|---|---|
| `lib/inventory_yaml.py` | R2 inventory YAML helpers (`seed-inventory`, bootstrap) |
| `lib/oci_free_tier.py` | Continuous free packs (solo 2/12, two 1/6) + boot ≤196 |
| `lib/omni_machine_match.py` | Omni UUID match: preferred pin → hostname → ipv4 |
| `reconcile-omni-machine-ids.py` | Persist `provider_data.omni_machine_id` into inventory |
| `validate-oci-free-tier.py` | CI/preflight inventory check |
| `reconcile-oci-free-tier-inventory.py` | Rewrite inventory to continuous free packs |
| `audit-oci-live-free-tier.sh` | Live OCI API free-tier audit (one tenancy) |
| `ensure-oci-free-tier-capacity.py` | Seed empty with 2/12/196; reconcile sizes |
| `prune-oci-free-tier-violators.sh` | Terminate live free-tier oversize VMs; optional orphan VCN teardown |

```bash
# Unit tests for free-tier helpers
python3 -m unittest scripts.lib.test_oci_free_tier -q
# or from scripts/lib:
python3 -m unittest test_oci_free_tier.py -q

```

---

## Security notes

- All operator scripts read SOPS-encrypted secrets via the operator's
  age key (`SOPS_AGE_KEY` env or `~/.config/sops/age/keys.txt`).
- Workflow-invoked scripts get secrets via the GitHub-Actions
  `secrets:` block; never echo them to logs.
- Cluster credentials are issued by Omni: `omnictl kubeconfig --cluster
  stawi --service-account` for kubeconfig, `omnictl talosconfig --cluster
  stawi` for talosconfig. The pre-Omni scripts that minted these
  client-side (`get-kubeconfig.sh`, `create-cluster-user.sh`,
  `dispatch-kubeconfig.yml`) were retired in 2026-04 with the Omni
  takeover.
