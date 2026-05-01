# scripts/

Operator + workflow tooling. Each script prints usage with `-h`/`--help` or
empty args. Most are invoked from `.github/workflows/`; a few are operator-
run during account onboarding.

## Operator-run

| Script | Purpose |
|---|---|
| `bootstrap-oci-oidc.sh` | Idempotently set up an OCI Identity Domain so GitHub Actions can WIF-federate into a new tenancy. Run once per OCI tenancy, usually in OCI Cloud Shell. |
| `seed-inventory.sh` | Append a new account stanza to the R2-backed inventory used by tofu's `node-state` module. |

## Workflow-invoked (don't run by hand)

| Script | Invoked by |
|---|---|
| `cluster-health.sh` | `cluster-health.yml` |
| `configure-oci-wif.sh` | `tofu-layer.yml` (OCI auth step) |
| `build-oci-auth-json.py` | `tofu-layer.yml` |
| `prune-stale-oci-instance-ocids.sh` + `.py` | `prune-stale-oci-ocids.yml` |
| `rename-inventory-accounts.sh` + `rename_inventory_keys.py` + `rename-inventory-keys.sh` | `rename-inventory-{accounts,keys}.yml` |
| `sync-sops-check.sh` + `check-sops-check-drift.sh` | pre-commit hooks |

## Shared library

`lib/inventory_yaml.py` — helpers for reading/writing the R2 inventory's YAML
files. Imported by `seed-inventory.sh` and `bootstrap-oci-oidc.sh`.

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
