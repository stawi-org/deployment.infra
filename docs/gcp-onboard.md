# GCP Spot workers — operator go-live

OpenTofu owns desired GCP capacity. Bootstrap configures **IAM/WIF only**
(WIF + SOPS auth + budget tripwire). After that: **apply**, not seed scripts.

### Safe to re-run anytime

`bootstrap-gcp-wif.sh` **never** stops, deletes, or recreates cluster VMs,
disks, VPCs, or Omni/Kubernetes state. Re-runs only add missing IAM/WIF
bindings. If the account is already on `main`, the script **skips the git
PR path** so `onboard-gcp` / full provision is not re-triggered. Use
`--iam-only` to force IAM-only, or `--force-repo-write` only when you
intentionally need a new auth PR.

Cluster day-2 apply (`cluster-provision` mode=`infra` or `full` with
`wipe_cluster=false`) is desired-state and must not wipe; wipe requires an
explicit confirm token.

Lifecycle, idempotency, and ghost prevention: **[docs/gcp-lifecycle.md](gcp-lifecycle.md)**.

## Model

| Concern | Owner |
|---|---|
| WIF pool / SA / encrypted auth / budget | `scripts/bootstrap-gcp-wif.sh` (once per project) |
| Default capacity (2× Spot `e2-standard-2`, 8 GiB) | OpenTofu `gcp-account-infra` when R2 nodes are empty |
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
| `gcloud` Owner (or equiv.) | Bootstrap creates WIF + SA; billing-budget admin for alerts |
| Upload `bootstrap-gcp-wif.sh` only | Script auto-clones the public repo into `~/deployment.infra` |
| `GITHUB_TOKEN` (recommended on Cloud Shell) | Non-interactive push + PR. Without it GCP still completes; re-run with a token to push |

SOPS encrypts with the **public** age key in `.sops.yaml` — you do **not**
need the private age key on the bootstrap machine. The script also
auto-installs `sops` into `~/.local/bin` when missing.

## Onboard

### GCP Cloud Shell (recommended — upload only the script)

```bash
# From ~ after uploading bootstrap-gcp-wif.sh
chmod +x ./bootstrap-gcp-wif.sh

# Recommended: PAT so push + PR never prompt (classic: repo scope)
export GITHUB_TOKEN=ghp_xxxxxxxx

./bootstrap-gcp-wif.sh \
  --project YOUR_GCP_PROJECT_ID \
  --gh-profile stawi-prod \
  --region europe-west9
```

The script is **fully non-interactive** (never prompts for git username/password).
It installs `sops`, clones `stawi-org/deployment.infra` into
`~/deployment.infra` if needed, configures WIF/SA/budget, commits auth on a
branch, pushes (token or existing non-interactive creds; fork fallback if no
upstream write), and prints `OPEN: …`. Without a token, GCP still finishes and
the script prints how to re-run with `GITHUB_TOKEN` to push.

Or via curl (no upload):

```bash
curl -fsSL https://raw.githubusercontent.com/stawi-org/deployment.infra/main/scripts/bootstrap-gcp-wif.sh \
  | bash -s -- --project YOUR_GCP_PROJECT_ID --gh-profile stawi-prod
```

### Flags (parity with OCI bootstrap)

| Flag | Default | Notes |
|---|---|---|
| `--project` | *(required)* | GCP project id |
| `--region` | `europe-west9` | Paris FR — closest French GCE region to Marseille |
| `--gh-profile` | slug of project id | Key under `gcp:` + auth path segment |
| `--vpc-cidr` | `10.210.0.0/24` | Per-account VPC |
| `--repo-path` | auto | Existing checkout, else auto-clone `~/deployment.infra` |
| `--no-clone` | off | Fail instead of auto-cloning |
| `--base-branch` | `main` | Worktree base |
| `--branch` | `onboard-gcp-<profile>` | Push branch (reused) |
| `--no-push` / `--no-pr` | off | Local-only / skip REST PR open |
| `--budget-amount` | `50` | Monthly Cloud Billing budget (USD) |
| `--budget-email` | git `user.email` | Hint only; billing admins get default alerts |
| `--budget-name` | `stawi-gcp-workers` | Budget display name |
| `--no-budget` | off | Skip budget ensure |

`GITHUB_TOKEN` / `GH_TOKEN` is **optional**. Without it the script still
pushes with your git credentials and prints `OPEN: https://github.com/…/compare/…`.
With a token it also creates the PR via the GitHub REST API (no `gh` CLI).

Default region is **`europe-west9` (Paris)** — closest French GCE region to
Marseille (GCP has no Marseille zone). **CNPG** (deployment.manifests) requires
`node.stawi.org/role-database=true` and `provider NotIn contabo`. Infra sets
`role-database=true` on OCI and **`false` on GCP/Contabo** so Postgres stays
on OCI. See [docs/node-labels.md](node-labels.md).

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
- Lifecycle: [docs/gcp-lifecycle.md](gcp-lifecycle.md)
