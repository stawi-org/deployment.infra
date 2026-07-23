# scripts/

Operator + workflow tooling. Each script prints usage with `-h`/`--help` or
empty args. Most are invoked from `.github/workflows/`; a few are operator-
run during account onboarding.

## Operator-run

| Script | Purpose |
|---|---|
| `bootstrap-oci-oidc.sh` | Idempotently set up an OCI Identity Domain so GitHub Actions can WIF-federate into a new tenancy. Run once per OCI tenancy, usually in OCI Cloud Shell. |
| `bootstrap-gcp-wif.sh` | Idempotently set up GCP Workload Identity Federation (pool/provider/SA/IAM) for GitHub Actions, write SOPS `auth.yaml`, add the account under `gcp:` in `accounts.yaml`, push `onboard-gcp-<profile>`, and open a PR. Run once per GCP project. |
| `seed-inventory.sh` | Append a new account stanza to the R2-backed inventory used by tofu's `node-state` module. |

## Workflow-invoked (don't run by hand)

| Script | Invoked by |
|---|---|
| `cluster-health.sh` | `cluster-health.yml` |
| `configure-oci-wif.sh` | `tofu-layer.yml` (OCI auth step) |
| `build-oci-auth-json.py` | `tofu-layer.yml` |
| `stage-gcp-auth-from-repo.sh` | `onboard-gcp.yml`, `tofu-layer.yml`, `sync-talos-images.yml` (decrypt repo GCP auth for WIF) |
| `ensure-gcp-default-capacity.py` | `onboard-gcp.yml` (seed empty R2 inventories with 2× Spot e2-medium) |
| `check-talos-image-catalog.py` | `cluster-provision`, `onboard-gcp`, `sync-talos-images` (skip image rebuild when catalog complete) |
| `prune-stale-oci-instance-ocids.sh` + `.py` | `prune-stale-oci-ocids.yml` |
| `rename-inventory-accounts.sh` + `rename_inventory_keys.py` + `rename-inventory-keys.sh` | `rename-inventory-{accounts,keys}.yml` |
| `sync-sops-check.sh` + `check-sops-check-drift.sh` | pre-commit hooks |

## Shared library

| Module | Purpose |
|---|---|
| `lib/inventory_yaml.py` | R2 inventory YAML helpers (`seed-inventory`, bootstrap) |
| `lib/oci_free_tier.py` | Continuous free packs (solo 2/12, two 1/6) + boot ≤196 |
| `lib/gcp_default_pack.py` | Default two Spot workers pack + inventory validation |
| `lib/talos_image_catalog.py` | Catalog readiness (schematic + per-account image handles) |
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

# Unit tests for GCP default Spot pack + image catalog gate
cd scripts/lib && python3 -m unittest test_gcp_default_pack.py test_talos_image_catalog.py -q
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
