# GCP Spot workers — operator go-live

How to land the peer provider code and attach the first (or next) GCP project
as **two Spot `e2-medium` Talos workers**. Workers only — no control plane on GCE.

## Prerequisites

| Need | Why |
|---|---|
| This repo’s GCP code on `main` | Workflows (`onboard-gcp`, `02-gcp-infra`, image import) must already exist on `main` before the onboard PR |
| GCP project with **billing enabled** | Spot GCE is paid; set a **~$50/month budget alert** in Cloud Billing |
| `gcloud` authed as Owner (or equiv. IAM + service enable) | Bootstrap creates WIF + SA + roles |
| `jq`, `curl`, `python3`, `git` | Bootstrap tooling |
| `GITHUB_TOKEN` / `GH_TOKEN` with **Contents + Pull requests** on `stawi-org/deployment.infra` | Push branch + open PR |
| Age private key for SOPS (`SOPS_AGE_KEY` or `~/.config/sops/age/keys.txt`) | Encrypt `auth.yaml` to the repo recipient |
| Repo secrets already set for CI | `SOPS_AGE_KEY`, R2, Omni SA, etc. (same as OCI) |

Cost model (planning): **2× Spot e2-medium + 50 GB pd-standard + public IPv4** is typically **~$32–36/month** in `europe-west1`, leaving headroom under a $50 budget for egress. Do **not** seed a third worker until you have measured egress. See design notes in `docs/superpowers/specs/2026-07-22-gcp-workers-design.md`.

## Path A — first time (platform code not on main yet)

```bash
# 1) Merge the GCP peer-provider PR (feat/gcp-workers) into main.
#    Empty gcp: [] — no projects yet; matrices skip cleanly.

# 2) Bootstrap a real project (from a clean checkout of main after merge):
export GITHUB_TOKEN=ghp_...   # or GH_TOKEN
./scripts/bootstrap-gcp-wif.sh \
  --project YOUR_GCP_PROJECT_ID \
  --gh-profile stawi-prod \
  --region europe-west1

# 3) Review + merge the PR it opens (onboard-gcp-<profile>).
#    On push to main: onboard-gcp.yml seeds R2 inventory + cluster-provision.

# 4) Verify (below).
```

## Path B — add another project (platform already on main)

Same as step 2–4 above with a new `--project` / `--gh-profile`. Each project gets its own state key `production/02-gcp-infra-<profile>.tfstate` and R2 path `production/inventory/gcp/<profile>/nodes.yaml`.

### Bootstrap flags

```text
--project <ID>       required
--region             default europe-west1
--gh-profile         accounts.yaml key (default: slug of project id tail)
--vpc-cidr           default 10.210.0.0/24  (keep unique vs OCI VCNs)
--no-push / --no-pr  local dry-run of the git side
```

Bootstrap is **idempotent**: re-run to repair WIF/SA/IAM or re-open the PR.

## What CI does after the onboard PR merges

1. **`onboard-gcp`**
   - Decrypts repo auth for region defaults
   - Seeds empty `production/inventory/gcp/<account>/nodes.yaml` with **2 Spot workers**
   - **Catalog gate:** if R2 `talos-images.yaml` already covers every roster account, provision with **`mode=infra`** (no image rebuild). First project (missing GCE self_link) uses **`mode=full`** once.
2. **`sync-talos-images`** (only when catalog incomplete or force)
   - Downloads Omni **GCP amd64** media (R2-cached when schematic unchanged)
   - WIF → stages GCS → creates custom GCE image → writes `formats.gcp.accounts.<account>.self_link` into R2 `talos-images.yaml`
   - **No-op** when schematic matches and every account already has an image handle
3. **`tofu-apply` → `02-gcp-infra`**
   - VPC + firewall + 2× Spot GCE instances (maintenance mode / SideroLink image)
4. **`03-talos` + DNS**
   - Labels Omni machines (`node.stawi.org/role=worker`, `provider=gcp`, `spot=true`)
   - Per-node `node-gcp` patches (hostname + Flannel public-ip overwrite)
5. Machines match MachineClass **`workers`**

### Fast path after the first import

Images are **not** rebuilt per node or per scale-out:

```bash
# Add a worker: edit R2 nodes.yaml, then infra only
gh workflow run cluster-provision.yml -f mode=infra
```

| Action | Mode | Rebuilds images? |
|---|---|---|
| First GCP project onboard | `full` (automatic) | Once |
| Re-run onboard / add nodes (catalog ready) | `infra` | No |
| Bump Talos / schematic | `images` or `full` + optional force | Yes |
| Never for scale | `force_image_sync=true` | Avoid |

## Verification checklist

```bash
# Inventory
aws s3 cp s3://cluster-tofu-state/production/inventory/gcp/<account>/nodes.yaml - \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" --region us-east-1

# Image catalog must include this account
aws s3 cp s3://cluster-tofu-state/production/inventory/talos-images.yaml - \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" --region us-east-1 \
  | yq '.formats.gcp.accounts'

# GCE
gcloud compute instances list --project=YOUR_PROJECT_ID

# Omni (machines should show provider=gcp, role=worker)
omnictl get machines -o yaml | yq '.[] | select(.metadata.labels["node.stawi.org/provider"]=="gcp")'
```

Expect:

- [ ] Two GCE Spot VMs named `gcp-<account>-node-1` and `…-node-2`
- [ ] Both register in Omni and receive standard labels
- [ ] Both are eligible for MachineClass `workers`
- [ ] Nodes are **Ready** in Kubernetes after KubeSpan joins

## Day-2 operations

| Action | How |
|---|---|
| Change size / zone / Spot vs Standard | Edit R2 `nodes.yaml` (`machine_type`, `zone`, `preemptible`), then `tofu-apply` / `cluster-provision` mode=infra |
| Add a 3rd worker | Append a node under `nodes:` in R2 inventory (keep `role: worker`) |
| Force reimage | Bump `force_reinstall_generation` in `tofu/layers/02-gcp-infra/terraform.tfvars` and apply |
| Re-run seed only | `gh workflow run onboard-gcp.yml -f dry_run=true` then without dry_run |
| Full provision again | `gh workflow run cluster-provision.yml -f mode=full -f force_image_sync=true` |

## Workload placement (reliability)

GCP capacity is **interruptible**. Prefer:

- Stateless / multi-replica / batch on Spot (`node.stawi.org/capacity-class=spot` or `node.stawi.org/spot=true`)
- Single-replica stateful and control-plane-adjacent work on Contabo / non-Spot only

Do **not** put etcd or Kubernetes control plane on GCE.

## Failure modes

| Symptom | Likely cause | Fix |
|---|---|---|
| `02-gcp-infra` fails: no image self_link | Image import skipped / failed | Re-run `sync-talos-images` or `cluster-provision` mode=images; check WIF |
| WIF auth error in Actions | Pool/provider/SA binding wrong | Re-run `bootstrap-gcp-wif.sh` (idempotent) |
| Seed did nothing | `nodes.yaml` already non-empty | Edit inventory manually; seed only fills empty accounts |
| Spot VM gone | Preemption (expected) | Next apply recreates from inventory |
| Budget spike | Egress or extra nodes | Cap inventory at 2; Cloud Billing budget alert |

## Related

- Design: [docs/superpowers/specs/2026-07-22-gcp-workers-design.md](superpowers/specs/2026-07-22-gcp-workers-design.md)
- Example inventory shape: [docs/config/gcp/stawi-prod.yaml](config/gcp/stawi-prod.yaml)
- Topology boundary: [docs/topology.md](topology.md)
- Orchestrated provision: [docs/cluster-provision.md](cluster-provision.md)
