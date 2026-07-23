# GCP Spot workers — operator go-live

OpenTofu owns desired GCP capacity. Bootstrap is the only one-shot
script (WIF + SOPS auth). After that: **apply**, not seed scripts.

Lifecycle, idempotency, and ghost prevention: **[docs/gcp-lifecycle.md](gcp-lifecycle.md)**.

## Model

| Concern | Owner |
|---|---|
| WIF pool / SA / encrypted auth | `scripts/bootstrap-gcp-wif.sh` (once per project) |
| Default capacity (2× Spot `e2-medium`) | OpenTofu `gcp-account-infra` when R2 nodes are empty |
| Custom size / zone / count | R2 `production/inventory/gcp/<account>/nodes.yaml` |
| Omni-aware image bytes | `sync-talos-images` (idempotent; weekly + onboard) |
| Boot which image | OpenTofu: catalog `self_link` or family `stawi-talos` |
| VPC / VMs / labels | OpenTofu layers `02-gcp-infra` + `03-talos` |

Workers only — no control plane on GCE. Spot by default.

## Prerequisites

| Need | Why |
|---|---|
| GCP peer-provider code on `main` | Workflows + modules present |
| Billing-enabled GCP project | Spot is paid (~$32–36/mo for default pack + headroom under $50) |
| `gcloud` Owner (or equiv.) | Bootstrap creates WIF + SA |
| `GITHUB_TOKEN` / `GH_TOKEN` | Bootstrap PR |
| SOPS age key | Encrypt auth.yaml |

## Onboard

```bash
export GITHUB_TOKEN=...
./scripts/bootstrap-gcp-wif.sh \
  --project YOUR_GCP_PROJECT_ID \
  --gh-profile stawi-prod \
  --region europe-west1
```

Merge the PR. `onboard-gcp` runs `cluster-provision` mode=full:

1. **Images** — import Omni media into this project if missing (reuse if present)
2. **OpenTofu** — VPC + two Spot workers (defaults) + write inventory back to R2
3. **03-talos** — labels / patches → Omni MachineClass `workers`

## Day-2 (scale / change)

```bash
# Edit R2 inventory, then apply desired state only (no image pipeline):
gh workflow run cluster-provision.yml -f mode=infra
```

| Goal | Action |
|---|---|
| Add a worker | Append node under R2 `nodes:` → `mode=infra` |
| Change machine type | Edit inventory → `mode=infra` |
| Force reimage | Bump `force_reinstall_generation` in `02-gcp-infra` → apply |
| New Talos schematic | `mode=images` or weekly schedule; existing VMs keep disks |

Do **not** put single-replica stateful work on Spot.

## Verify

```bash
gcloud compute instances list --project=YOUR_PROJECT_ID
omnictl get machines -o yaml | yq '.[] | select(.metadata.labels["node.stawi.org/provider"]=="gcp")'
```

## Related

- Topology: [docs/topology.md](topology.md)
- Provision modes: [docs/cluster-provision.md](cluster-provision.md)
- Example shape: [docs/config/gcp/stawi-prod.yaml](config/gcp/stawi-prod.yaml)
