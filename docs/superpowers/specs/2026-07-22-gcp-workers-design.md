# GCP GCE workers — design

> **Status:** Implemented — OpenTofu owns default Spot pack + image resolution; bootstrap is WIF-only. See [docs/gcp-onboard.md](../../gcp-onboard.md).
> **Date:** 2026-07-22
> **Scope:** Full peer provider for paid Google Compute Engine workers: multi-project inventory, Workload Identity Federation, bootstrap PR flow, OpenTofu layer, Omni-aware image import, and post-merge cluster expand. Single implementation plan (multiple PRs OK).

## Goal

Add **Google Cloud Platform (GCE)** as a fourth node ownership mode in `deployment.infra`, peer to Contabo, OCI, and on-prem:

1. Operators onboard a GCP **project** the same way they onboard an OCI tenancy: one bootstrap script → PR → merge → automatic seed + provision.
2. GitHub Actions authenticates with **Workload Identity Federation** (no long-lived SA JSON keys).
3. OpenTofu provisions **paid Spot/preemptible** GCE VMs as **Talos workers only**, joined via Omni/SideroLink and KubeSpan.
4. **Default capacity per project:** two Spot workers (seeded when inventory is empty).
5. Inventory, per-account state, image sync, and cluster-provision matrix follow existing patterns so multi-project growth does not require redesign.

## Non-goals (v1)

- GCP-hosted control plane / etcd (topology boundary unchanged).
- Always Free / free-tier guardrails (this is paid capacity; no OCI-style packing validators).
- GKE, Cloud Run, or managed Kubernetes.
- Dual-stack IPv6 on GCP VPCs (IPv4-first; IPv6 is a follow-up).
- Shared image project across accounts (per-project custom images first).
- Multi-arch inventory in v1 (amd64 only; arm64 later if needed).
- Auto-scaling beyond the inventory-declared node set (operators edit `nodes.yaml` to change count).

## Why

The fleet already spreads workers across Contabo, multi-tenancy OCI Always Free, and on-prem. Paid GCE workers add:

- Predictable general-purpose capacity when Always Free quotas are exhausted or wrong shape.
- Multi-project isolation (partner / environment / billing boundaries) with the same operator path as OCI.
- A second public-cloud API surface that still terminates on Omni + Flux, not a second cluster lifecycle.

Workers-only keeps etcd off WAN-joined GCE paths, consistent with [docs/topology.md](../../topology.md).

## Architecture

```
Operator (gcloud auth)
        │
        ▼
bootstrap-gcp-wif.sh
  • WIF pool/provider + SA + IAM (idempotent)
  • SOPS auth.yaml + accounts.yaml (worktree)
  • PR → main
        │
        ▼
onboard-gcp.yml (push to main)
  1. Seed default nodes.yaml in R2 (if empty)
  2. cluster-provision (images → tofu-apply → template)
        │
        ▼
sync-talos-images (+ gcp-import matrix)
        │
        ▼
02-gcp-infra (per project cell)
  VPC / subnet / firewall / GCE workers
        │
        ▼
Omni SideroLink → labels → workers MachineClass
        │
        ▼
03-talos patches + KubeSpan
```

### Placement among ownership modes

| Mode | Layer | Auth | Role default |
|---|---|---|---|
| Contabo | `01-contabo-infra` | Contabo API secrets | controlplane + workers |
| OCI | `02-oracle-infra` | OCI OIDC / WIF | workers (and some CP packing) |
| On-prem | `02-onprem-infra` | inventory only | worker (manual apply) |
| **GCP (new)** | **`02-gcp-infra`** | **GCP WIF** | **worker only** |

Omni host and Kubernetes control-plane topology are **unchanged** (Contabo Omni host; existing CP placement).

## Inventory model

Same two-plane model as OCI.

### Repo roster

`tofu/shared/accounts.yaml`:

```yaml
gcp:
  - stawi-prod
  - partner-a
```

### Repo auth (SOPS)

Path: `tofu/shared/accounts/gcp/<account>/auth.yaml`

```yaml
auth:
  project_id: stawi-prod-123456
  region: europe-west1
  vpc_cidr: 10.210.0.0/24
  workload_identity_provider: projects/123456/locations/global/workloadIdentityPools/github/providers/github-actions
  service_account_email: tofu-gcp@stawi-prod-123456.iam.gserviceaccount.com
```

No service-account private keys. CI exchanges the GitHub OIDC token for a short-lived SA credential via the WIF provider.

### R2 node inventory

Path: `production/inventory/gcp/<account>/nodes.yaml`

```yaml
labels:
  node.stawi.org/capacity-pool: gce-general
annotations: {}
nodes:
  gcp-stawi-prod-node-1:
    role: worker
    machine_type: e2-medium
    zone: europe-west1-b
    boot_disk_gb: 50
    preemptible: true          # default; Spot provisioning_model
    labels: {}
    annotations: {}
  gcp-stawi-prod-node-2:
    role: worker
    machine_type: e2-medium
    zone: europe-west1-b
    boot_disk_gb: 50
    preemptible: true
    labels: {}
    annotations: {}
```

**Default pack:** every empty account seeds **exactly two** Spot workers (`gcp-<account>-node-1` and `gcp-<account>-node-2`). Both use `preemptible: true` (GCE Spot). Operators may set `preemptible: false` per node for standard VMs, or change `machine_type` / `zone` / count via R2 inventory.

**Spot semantics:** `google_compute_instance.scheduling` uses `provisioning_model = "SPOT"`, `preemptible = true`, `automatic_restart = false`, `on_host_maintenance = "TERMINATE"`, `instance_termination_action = "DELETE"`. Preemption is expected; next tofu apply recreates missing instances from inventory. Workloads on these nodes must tolerate interruption (prefer non-critical / replicated workers).

**Role enforcement:** inventory validators and the OpenTofu module accept only `role: worker` in v1. Control-plane values fail plan/validate.

**Canonical node names** (Omni / K8s): `gcp-<account>-<node-key>` (RFC 1123-safe), parallel to `oci-<account>-…`.

### Optional docs example

`docs/config/gcp/stawi-prod.yaml` documents the shape for operators (R2 remains source of truth for nodes at apply time).

## Bootstrap + onboard flow

### `scripts/bootstrap-gcp-wif.sh`

Idempotent operator script, patterned on `scripts/bootstrap-oci-oidc.sh`.

**Prereqs:** `gcloud` (authed to the target project with sufficient IAM), `jq`, `curl`, `python3`, `git`, `sops` (auto-install into `~/.local/bin` like OCI), `GITHUB_TOKEN` / `GH_TOKEN` (Contents + Pull requests on `stawi-org/deployment.infra`).

**Flags (parity):** `--project`, `--region`, `--gh-profile`, `--vpc-cidr`, `--repo-path`, `--base-branch`, `--branch`, `--no-push`, `--no-pr`, optional budget flags.

**GCP resources ensured:**

| Resource | Purpose |
|---|---|
| Workload Identity Pool `github` | Trust GitHub OIDC |
| OIDC provider `github-actions` | Issuer `https://token.actions.githubusercontent.com` |
| Attribute condition | Restrict to repository `stawi-org/deployment.infra` |
| SA `tofu-gcp@PROJECT.iam` | Impersonation target for OpenTofu / image import |
| Project IAM on SA | Enough for compute, network, custom images, and GCS image staging (least privilege documented in implementation plan) |
| WIF → SA binding | `roles/iam.workloadIdentityUser` for the pool principal set |

Optional monthly budget alert (default tripwire, e.g. $50/month — not a hard provisioner stop).

**Repo writes (isolated):**

- Only `tofu/shared/accounts/gcp/<gh-profile>/auth.yaml` (SOPS-encrypted)
- One list entry under `gcp:` in `tofu/shared/accounts.yaml`
- Worktree off `origin/<base>`; branch `onboard-gcp-<gh-profile>` reused; PR via GitHub REST (no `gh` CLI required)

Re-runs do not thrash other accounts or rewrite unchanged auth.

### `.github/workflows/onboard-gcp.yml`

**Triggers:**

- `push` to `main` on `tofu/shared/accounts.yaml` or `tofu/shared/accounts/gcp/**`
- `workflow_dispatch` (`deploy_flux`, `dry_run`)

**Jobs:**

1. **seed-default-nodes** — sync R2 `production/inventory/gcp/`; for every `gcp:` account with empty/missing `nodes.yaml`, write default paid pack; upload `*/nodes.yaml`. No free-tier validators.
2. **provision** — calls `cluster-provision.yml` with `mode=full`, `wipe_cluster=false`, `deploy_flux` only when dispatch opts in.

### Default seed (empty account)

Exactly **two** Spot workers:

```yaml
nodes:
  gcp-<account>-node-1:
    role: worker
    machine_type: e2-medium
    zone: <auth.region>-b
    boot_disk_gb: 50
    preemptible: true
  gcp-<account>-node-2:
    role: worker
    machine_type: e2-medium
    zone: <auth.region>-b
    boot_disk_gb: 50
    preemptible: true
```

Operators may edit R2 inventory before or after first apply to change type, zone, count, preemptible flag, or labels. Non-empty inventories are left unchanged by the seed step (no continuous reconciliation like OCI free-tier).

## OpenTofu modules and layer

### Layer `tofu/layers/02-gcp-infra`

- Backend key: `production/02-gcp-infra-<account>.tfstate` when `var.account_key` is set (same matrix pattern as oracle/contabo/onprem).
- Reads `accounts.yaml` → single account key for the cell.
- `module "gcp_account_state"` → `node-state` with `provider_name = "gcp"`.
- Google provider configured with project from auth + ADC from the workflow WIF step.
- Instantiates `gcp-account-infra` once per cell.

### Module `gcp-account-infra`

Owns per-project:

- VPC + subnet in `auth.region` with `vpc_cidr`
- Firewall rules (see Networking)
- Image presence check against staged `talos-images.yaml`
- `for_each` over inventory nodes → `node-gcp`
- R2 nodes writer (observed `provider_data`: instance id, IPs, zone, machine type)

### Module `node-gcp`

- `google_compute_instance` named `gcp-<account>-<node-key>`
- Inputs: machine_type, zone, boot_disk_gb, image, network/subnet, labels, annotations, `force_reinstall_generation`
- Validation: `role == "worker"`
- `can_ip_forward = true`
- Ephemeral public IPv4
- Boot from Omni-aware custom image; **maintenance mode** (no full machine config in metadata) — SideroLink kernel parameters come from the Omni-built image, matching OCI’s model
- Derived labels: `node.stawi.org/provider=gcp`, `node.stawi.org/account`, `node.stawi.org/role=worker`, region/zone
- Outputs for layer-03 contract and R2 writeback

### Patch `tofu/shared/patches/node-gcp.tftpl`

Per-node Talos patch (layer 03):

- `machine.nodeLabels` / `nodeAnnotations`
- Flannel public-ip overwrite when external IPv4 ≠ primary NIC address (GCP external IP is often 1:1 NAT to the primary internal IP — same class of problem as OCI)
- `HostnameConfig` pin

### Layer 03 integration

- Aggregate `gcp` provider accounts into the global node set alongside contabo/oracle/onprem.
- Emit contracts and apply `node-gcp.tftpl` for each GCP node.
- Existing Omni MachineClass `workers` (`node.stawi.org/role=worker`) requires **no** schema change.

## Networking

| Item | v1 choice |
|---|---|
| VPC name | `stawi-<account>` |
| Subnet | `stawi-<account>-workers` in default region |
| Public IPv4 | Ephemeral external IP per VM |
| IPv6 | Off |
| Egress | Allow all (SideroLink to Omni, registry, etc.) |
| Ingress | KubeSpan UDP 51820; optional Talos API 50000 from documented operator CIDRs only; no broad open Kubernetes API on public IP |
| Bastion | Not required |

### CIDR allocation note

Document a private range map so GCP VPC CIDRs do not collide with OCI VCNs or Contabo host addressing used in KubeSpan debugging. Suggested starting allocation:

| Provider | Example range |
|---|---|
| GCP account N | `10.210.0.0/24`, `10.210.1.0/24`, … (default /24 per project) |
| OCI accounts | Existing per-account VCN CIDRs |
| Cluster pod/service | Existing IPv6-first cluster CIDRs (unchanged) |

Operators override `vpc_cidr` in auth.yaml when needed.

## Image pipeline

Extend `.github/workflows/sync-talos-images.yml`:

1. **build** — also download **GCP amd64** Omni-aware image via `omnictl download` (same Admin SA secret as today); cache bytes in the public image R2 bucket.
2. **discover-gcp** — enumerate `gcp:` accounts from staged auth / accounts.yaml; emit matrix `{account, project_id, region, wif…}`.
3. **gcp-import** — per account: WIF auth → stage object in project GCS → create/update custom GCE image → emit artifact `{account, self_link, family, schematic_id, sha256}`. Reuse image when display name / checksum already matches.
4. **assemble-and-upload** — merge into `production/inventory/talos-images.yaml`:

```yaml
formats:
  gcp:
    accounts:
      stawi-prod:
        self_link: projects/…/global/images/talos-…
        schematic_id: …
        sha256: …
```

`gcp-account-infra` plan fails if nodes are non-empty and the account has no image entry (mirror OCI’s `check "talos_image_ocid_present_when_nodes_exist"`).

`cluster-provision` and `onboard-gcp` run image sync before `02-gcp-infra` apply so new projects never race empty image catalogs.

## CI / workflow surface

| Component | Change |
|---|---|
| `scripts/bootstrap-gcp-wif.sh` | New |
| `scripts/stage-gcp-auth-from-repo.sh` | New — decrypt/stage auth for CI like oracle |
| OpenTofu `gcp-account-infra` defaults | Empty inventory → two Spot workers (no seed script) |
| `.github/workflows/onboard-gcp.yml` | New |
| `.github/workflows/sync-talos-images.yml` | discover + import + assemble for gcp |
| `.github/workflows/tofu-layer.yml` | Layer `02-gcp-infra`, WIF step, inventory sync `gcp/` |
| `.github/workflows/tofu-apply.yml` / `tofu-plan.yml` | Matrix over `gcp:` keys |
| `.github/workflows/cluster-provision.yml` | Include GCP image + apply legs |
| `README.md`, `docs/topology.md`, `scripts/README.md` | Document fourth mode |
| `docs/config/gcp/*.yaml` | Example inventory |

### `tofu-layer.yml` GCP auth step

When `inputs.layer == '02-gcp-infra'`:

1. Stage account auth from repo (`stage-gcp-auth-from-repo.sh`).
2. Authenticate with `google-github-actions/auth` (or equivalent) using that account’s `workload_identity_provider` + `service_account_email`.
3. Sync `production/inventory/gcp/<account>/` into the local inventory dir.
4. Export `TF_VAR_account_key` and run plan/apply as today.

## Security

- No long-lived GCP keys in GitHub secrets or repo files.
- WIF attribute condition pins repository (and optionally ref) so forks cannot impersonate.
- SOPS continues to protect auth.yaml contents at rest in git.
- Firewall stays deny-by-default for management ports; Omni remains the control channel.
- Budget alerts are advisory; billing protection remains a GCP org/project concern.

## Testing strategy

- Unit tests for seed/ensure scripts (empty account → default pack; non-empty unchanged).
- Inventory schema validation: reject non-worker roles.
- OpenTofu: `tofu validate` / plan with mocked or recorded credentials in CI where feasible; at minimum fmt + validate on the new layer.
- Bootstrap script: dry-run / `--no-push` path in docs; manual first-project onboard as acceptance.
- Image import: reuse path when checksum matches (idempotent re-run).
- End-to-end acceptance: one real project onboard → PR merge → worker registers in Omni → labels → joins `workers` MachineClass.

## Rollout plan (implementation order)

Suggested PR sequence (can be adjusted in the implementation plan):

1. **Spec + docs** (this document) + topology/README skeleton.
2. **Inventory + accounts schema** — `accounts.yaml` key, node-state `gcp` paths, seed script, example config.
3. **Bootstrap + stage auth + onboard workflow** (seed only / dry-run safe).
4. **Image pipeline** — gcp download + import + `talos-images.yaml` shape.
5. **OpenTofu modules + `02-gcp-infra`** + tofu-layer/apply matrix wiring.
6. **Layer 03 patches + cluster-provision integration**.
7. **First live project onboard** + operational notes.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Omni image platform support for GCP differs from oracle/metal | Confirm `omnictl download` platform id in implementation; pin documented format |
| External IP / Flannel public-ip mismatch | `node-gcp.tftpl` annotations; mirror OCI patch lessons |
| CIDR collision with existing VCNs | Document map; require unique `vpc_cidr` per project |
| WIF misconfiguration locks CI out | Bootstrap is idempotent; document `gcloud` re-run; keep plan/apply error messages pointing at auth.yaml fields |
| Cost runaway | Optional budget alert; seed two Spot `e2-standard-2` only; no auto-scale in v1 |
| Spot preemption churn | Expected; tofu recreates; label Spot nodes so operators avoid stateful single-replicas |
| Scope creep into CP-on-GCP | Hard-fail non-worker roles in module + seed validators |

## Success criteria

- A new GCP project can be onboarded with only `bootstrap-gcp-wif.sh` + PR merge (no manual R2 auth upload).
- After merge, at least one GCE Talos worker appears in Omni, receives standard labels, and is allocatable in the `workers` MachineClass.
- Adding a second project is a second bootstrap + merge; no layer redesign.
- No SA JSON keys are stored in the repository or as long-lived GitHub secrets for GCP.

## Open questions resolved in design

| Question | Decision |
|---|---|
| Capacity type | Paid Spot/preemptible GCE workers |
| Default pack | 2 Spot `e2-standard-2` (8 GiB) workers per empty account |
| Auth | Workload Identity Federation |
| Multi-project | Yes, with OCI-like bootstrap PR + onboard workflow |
| Roles | Workers only |
| IPv6 | Deferred after v1 |
| Approach | Full peer provider (Approach A) |
