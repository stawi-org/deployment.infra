# Omni-on-OCI cluster realignment — design

> **Status:** **Superseded** by [`2026-05-03-omni-contabo-realignment-design.md`](./2026-05-03-omni-contabo-realignment-design.md). This spec described the OCI-centric realignment shipped in PR #156 (omni-host + sole CP on OCI bwire, all Contabo as workers). After running that topology, OCI public-IPv4 instability for stable-name endpoints (`cp.stawi.org`, kube-apiserver) made the central plane fragile; the 2026-05-03 spec moves omni + CP back to Contabo while preserving the OCI bucket / IAM / worker-capacity wins from this PR.
> **Date:** 2026-05-02
> **Scope:** Track A (single PR + single cutover window). Track B (R2→OCI tofu state migration) brainstormed separately.
> **Posture:** Greenfield. No production state to preserve; cluster currently degraded.

## Goal

Realign cluster topology, OCI accounts, and OCI IAM to a single coherent end-state in one PR + one apply window:

- Move omni-host compute onto OCI bwire (was Contabo VPS 202727781).
- Single OCI bwire account holds all OCI compute for the cluster's central plane (omni-host + sole control-plane Talos node) and all OCI buckets.
- All Contabo VPSes become Talos workers.
- All OCI resources fit inside Always-Free quotas.
- No new OCI tenancies, no new OCI IAM users.
- SSH-lockdown on omni-host (admin reachable only via WireGuard).
- Per-machine `node-contabo.tftpl` patch wired into cluster template, fixing Talos apid bind on Contabo nodes.

## Why

- Cluster has been wedged for weeks on Contabo apid-bind issues; per-machine LinkConfig patch authored but never wired (2026-04-30 → 2026-05-02 conversation arc).
- Current omni-host substrate (Contabo VPS) is a one-of-a-kind code path inside `tofu/modules/omni-host/`; consolidating onto OCI removes one provider's worth of plumbing.
- Bucket sprawl across two OCI tenancies (alimbacho67 + bwire) doubles credential management and complicates cross-tenancy reads. One bucket-tenancy simplifies operations.
- Service IAM users (`omni-backup-writer`, `cluster-image-uploader`) have proven unstable — flagged for disabling under OCI's account-management heuristics. Reusing the existing operator user removes the disruption vector.

## Architecture (target end-state)

### Compute

| VM | Account / provider | Spec | Role |
|---|---|---|---|
| `oci-bwire-omni` | bwire (OCI) | A1.Flex 2 OCPU / 12 GB / 90 GB | omni-host (NOT cluster) |
| `oci-bwire-node-1` | bwire (OCI) | A1.Flex 2 OCPU / 12 GB / 90 GB | cluster CP (sole) |
| `oci-alimbacho67-node-1` | alimbacho67 (OCI) | existing 4 OCPU / 24 GB | worker (was CP) |
| `oci-brianelvis33-node-1` | brianelvis33 (OCI) | existing | worker |
| `contabo-bwire-node-1` | bwire (Contabo) | existing V94 | worker (was CP) |
| `contabo-bwire-node-2` | bwire (Contabo) | existing V94 | worker (was CP) |
| `contabo-bwire-node-3` | bwire (Contabo) | existing V94 (freed from omni) | worker |
| `onprem-tindase-node-1` | tindase (on-prem) | — | out of scope |

OCI bwire compute exactly fills the Always-Free ARM quota (4 OCPU + 24 GB across 2 VMs, 180 GB block volume, 2 reserved IPv4).

Cluster topology: ControlPlane size 1, Workers size 5.

### Storage (all in OCI bwire)

| Bucket | Today | After |
|---|---|---|
| `cluster-image-registry` | alimbacho67 (public) | bwire (public) — recreated, alimbacho67 bucket destroyed |
| `cluster-state-storage` | bwire | bwire (no change) |
| `cluster-vault-storage` | bwire | bwire (no change) |
| `omni-backup-storage` | bwire | bwire (no change) |

`cluster-image-registry` is recreated empty in bwire; the next `regenerate-talos-images` run repopulates it. No data migration.

### IAM

Customer Secret Key minted in **bwire only**, against the existing operator user (looked up via `data "oci_identity_user"`). No new service users in any tenancy. The only consumer of an OCI CSK after this PR is the omni-host's `--etcd-backup-s3` flag (writes to `omni-backup-storage`); the public `cluster-image-registry` reads need no auth, and writes (from `regenerate-talos-images`) use the same bwire CSK. alimbacho67 / brianelvis33 / ambetera have no service IAM at all post-PR.

Trade-off accepted: a leaked CSK gives S3-compat access to all buckets in the bwire tenancy (admin-user scope). User has chosen stability over least-privilege.

### Network

- DNS `cp.stawi.org` (orange-cloud, proxied) + `cpd.stawi.org` (gray-cloud, direct) re-target the OCI omni-host's reserved IPv4/IPv6.
- WireGuard admin listener moves to `oci-bwire-omni` (UDP 51820). OCI security list ingress: 80/443, 8090, 8100, 50180/UDP, 51820/UDP. Egress: all.
- SSH on `oci-bwire-omni`: closed to public; reachable only via WG. Phase D delivered in same PR.

### Cluster spec

- ControlPlane MachineSet: size 1, `machineClass: cp` (selector: `role=controlplane`).
- Workers MachineSet: size 5, `machineClass: workers` (selector: `role=worker`).
- Per-node ConfigPatches for each Contabo node (label-targeted by `omni.sidero.dev/cluster=stawi` + `node.antinvestor.io/name=<nodename>`) carry `LinkAliasConfig`, `LinkConfig` (IPv4/IPv6 + gateways), and `HostnameConfig`. Rendered + applied by the `sync-cluster-template` workflow from each Contabo tfstate.

### Load-balancer targets (`prod.stawi.org` A/AAAA round-robin)

`node.kubernetes.io/external-load-balancer: "true"` set on:
- `oci-alimbacho67-node-1`
- `oci-brianelvis33-node-1`
- `contabo-bwire-node-1`

All other workers and the CP carry `false`.

## Decisions taken

| # | Decision | Choice |
|---|---|---|
| 1 | Omni-host module shape | **C — Replace existing module with OCI variant.** Contabo `omni-host` module deleted in same PR. |
| 2 | Per-machine patch delivery | **B — Standalone `ConfigPatches.omni.sidero.dev` resources, label-targeted.** Rendered by sync-cluster-template workflow from each Contabo tfstate. |
| 3 | `cluster-image-registry` migration | **Recreate-only.** No data sync; next `regenerate-talos-images` run repopulates. alimbacho67 bucket destroyed. |
| 4 | Cutover sequencing | **A — Single-PR, single-window cutover.** No dual-run, no verification window — greenfield permits this. |
| 5 | Bucket name preserved | Yes — `cluster-image-registry` keeps its name in bwire. |
| 6 | Omni-host VM naming | `oci-bwire-omni` (non-cluster). Cluster CP is `oci-bwire-node-1`. |
| 7 | OCI tenancy + IAM constraint | No new tenancies. No new IAM users. CSK minted against existing operator user. `omni-backup-iam.tf` + `cluster-image-uploader-iam.tf` collapse into shared `oci-operator-csk.tf`. |
| 8 | Tindase on-prem | Out of scope for this PR. |
| 9 | OCI compute shape | `VM.Standard.A1.Flex` (ARM Always-Free). |
| 10 | Inventory source of truth | R2 (`s3://cluster-tofu-state/production/inventory/<provider>/<account>/{auth,nodes}.yaml`). Local `providers/config/` is testing-only. |

## Components diff

### New tofu / module code

| Path | Purpose |
|---|---|
| `tofu/modules/omni-host-oci/` | OCI substrate omni-host. `oci_core_instance` (A1.Flex 2/12/90), reserved public IPv4+IPv6, security list (80/443/8090/8100/50180-udp/51820-udp), cloud-init runs omni/dex/cloudflared docker-compose stack, hourly omni-backup tarball to `omni-backup-storage`, WG admin listener, SSH-public-disabled. |
| `tofu/layers/02-oracle-infra/oci-operator-csk.tf` | bwire-only CSK via `data "oci_identity_user"` + `oci_identity_customer_secret_key`. Output named `omni_backup_writer_credentials` (same shape as today's deleted `omni-backup-iam.tf` output) so `sync-cluster-template.yml`'s tfstate reader keeps working without changes. The standalone `cluster_image_uploader_credentials` output is dropped — `regenerate-talos-images.yml` switches to read the same `omni_backup_writer_credentials` output (it's the same CSK either way). |
| `tofu/shared/clusters/per-node-patches.yaml.tmpl` | ConfigPatch resource template (one rendered + applied per Contabo node). |

### New R2 inventory writes

| R2 key | Content |
|---|---|
| `production/inventory/oracle/bwire/auth.yaml` | bwire OCI auth (sopsed). Pre-staged manually before merge — `node-state` reads at plan time. |
| `production/inventory/oracle/bwire/nodes.yaml` | `oci-bwire-omni` (role: omni, non-cluster) + `oci-bwire-node-1` (role: controlplane, LB false). |

### R2 inventory mutations (via `node-state` writers on apply, or one-shot operator script)

| R2 key | Change |
|---|---|
| `production/inventory/contabo/bwire/nodes.yaml` | `bwire-1` role `controlplane → worker`, LB true (no change). `bwire-2` role `controlplane → worker`, LB `true → false`. Add `bwire-3` (role: worker, LB: false). |
| `production/inventory/oracle/alimbacho67/nodes.yaml` | LB `false → true`. Role already worker. |
| `production/inventory/oracle/brianelvis33/nodes.yaml` | Verify LB `true`. |

### Modified tofu

| Path | Change |
|---|---|
| `tofu/layers/00-omni-server/main.tf` | Replace Contabo `module "omni_host"` with `module "omni_host_oci"`. Drop the `import { id = "202727781" }` block (Contabo VPS is no longer adopted here — it's freed for `01-contabo-infra` to re-adopt as bwire-3). New module *creates* the OCI VM from scratch (no `import` needed — VM doesn't exist pre-PR). DNS `cp` / `cpd` re-target the OCI VM's reserved IPv4 + instance-attached IPv6. Read CSK from `02-oracle-infra` (bwire) tfstate via `terraform_remote_state`. |
| `tofu/layers/00-omni-server/terraform.tfvars` | Drop Contabo-specific knobs. |
| `tofu/layers/02-oracle-infra/image-registry.tf` | `cluster-image-registry` resource gate flips `is_alimbacho67` → `is_bwire`. Delete the alimbacho67 bucket entirely (greenfield, safe to drop). |
| `tofu/layers/02-oracle-infra/omni-backup-iam.tf`, `cluster-image-uploader-iam.tf` | Both deleted; collapsed into `oci-operator-csk.tf`. |
| `tofu/layers/01-contabo-infra/imports.tf` (or `bootstrap`) | Re-add VPS 202727781 import as `contabo-bwire-node-3`. |
| `tofu/shared/bootstrap/contabo-instance-ids.yaml` | Re-add `contabo-bwire-node-3: "202727781"`. |
| `tofu/modules/node-contabo/main.tf` | Add `node.antinvestor.io/name = var.name` to `derived_labels` so per-node ConfigPatch label-selector resolves. |
| `tofu/shared/clusters/main.yaml` | `Workers.machineClass.size = 5`. ControlPlane size stays 1. |
| `tofu/shared/inventory/talos-images.yaml` | OCI image-import URLs flip to bwire bucket public URL. |
| `.github/workflows/sync-cluster-template.yml` | New step: read each Contabo tfstate, render `node-contabo.tftpl` per node, wrap in ConfigPatch resource, `omnictl apply`. CSK comes from new shared output. |
| `.github/workflows/regenerate-talos-images.yml` | OCI upload destination flips to bwire bucket. Drop alimbacho67 dual-write. CSK comes from shared output. |

### Deleted

- `tofu/modules/omni-host/` — Contabo substrate retired.
- `tofu/layers/02-oracle-infra/omni-backup-iam.tf`, `cluster-image-uploader-iam.tf` — collapsed.

## Data flow during cutover

### Pre-merge (operator, ~5 min)

- Verify OCI bwire tenancy active, Always-Free ARM quota unused, 2 reserved IPv4 budget free.
- Confirm OCI WIF federation set up for bwire (`02-oracle-infra` matrix already iterates `bwire` per `accounts.yaml`).
- Pre-stage `s3://cluster-tofu-state/production/inventory/oracle/bwire/auth.yaml` and `nodes.yaml` (chicken-and-egg on `node-state` plan-time read).
- Mutate existing-account R2 inventories (Contabo bwire roles, LB labels on Contabo bwire-1 and the OCI workers).
- Bump `force_reinstall_generation` in `01-contabo-infra/terraform.tfvars` and `02-oracle-infra/terraform.tfvars` so post-apply rolls every node onto a freshly-built image carrying the new SideroLink token.

### Apply phase 1 — `02-oracle-infra` matrix run (parallel cells)

- **alimbacho67 cell**: destroys `cluster-image-registry` bucket + `cluster-image-uploader` IAM resources. No compute changes.
- **bwire cell**: creates `cluster-image-registry` (public, empty), shared `oci-operator-csk.tf` outputs, `oci-bwire-node-1` VM (boots Talos maintenance, awaits Omni). `oci-bwire-omni` is **not** created here — it lives in `00-omni-server`.
- **brianelvis33 / ambetera cells**: CSK collapse only.

### Apply phase 2 — `00-omni-server`

- Reads bwire tfstate via `terraform_remote_state` for CSK + reserved IP.
- Creates `oci-bwire-omni` VM via new `omni-host-oci` module. Cloud-init runs the docker-compose stack with **fresh master keys + new SideroLink join token**. Lets-Encrypt DNS-01 cert via existing CF API token.
- DNS `cp.stawi.org` (orange-cloud), `cpd.stawi.org` (gray-cloud) flip to OCI VM's reserved IPv4/IPv6.
- End of phase 2: `https://cp.stawi.org/healthz` returns 200.

### Auto-trigger — `regenerate-talos-images.yml`

- Path-triggered by schematic changes in this PR (or `workflow_dispatch force=true`).
- Reads new SideroLink token from `cpd.stawi.org` via `omnictl`.
- Builds Talos images for Contabo (x86) + OCI (ARM) schematics with embedded token.
- Uploads to bwire `cluster-image-registry`.
- Opens auto-PR with new image checksums in `tofu/shared/inventory/talos-images.yaml`.

### Auto-PR merge — second tofu-apply

- **`02-oracle-infra` (all cells)**: VMs reinstall onto new images. `oci-bwire-node-1` registers with Omni as role:controlplane → binds to ControlPlane MachineSet. `oci-alimbacho67-node-1`, `oci-brianelvis33-node-1` register as role:worker.
- **`01-contabo-infra`**: `force_reinstall_generation` bumped, all 3 Contabo VPSes (including freed 202727781 newly imported as bwire-3) reinstall onto new images. Contabo nodes register as role:worker.

### Auto-trigger — `sync-cluster-template.yml`

- Path-triggered by `tofu/shared/clusters/**` changes.
- Applies `machine-classes.yaml`, `main.yaml` (Workers size 5).
- New step: reads each Contabo tfstate, renders `node-contabo.tftpl` per node with IPv4/IPv6/gateway/hostname, wraps in `ConfigPatches.omni.sidero.dev` with `target_label_selectors: [omni.sidero.dev/cluster=stawi, node.antinvestor.io/name=<n>]`, `omnictl apply`s each.
- Applies `etcd-backup-s3-configs.yaml.tmpl` rendered from new shared CSK output.

### Apply phase 3 — `03-talos`

- Machine-labels reconciler (`sync-machine-labels.sh`) applies `MachineLabels` per node (role, name, provider, account, LB).
- Labels stick → MachineClass selectors match → Machines bind:
  - `oci-bwire-node-1` → `cp` MachineSet
  - 5 worker-labelled machines → `workers` MachineSet
- Per-node ConfigPatches pulled into per-machine config. Contabo nodes get correct LinkConfig → apid binds → cluster bootstraps.
- etcd boots on `oci-bwire-node-1`; kube-apiserver Ready; workers join.

End state: 1 CP + 5 workers Ready, `prod.stawi.org` round-robins across the 3 LB nodes, Omni dashboard at `cp.stawi.org`, etcd-backup-s3 hourly snapshots flowing.

## Risks + rollback

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| OCI Always-Free quota silently capped (ARM pool, reserved IPv4 budget) | medium | apply fails partway | Pre-merge verification (Gate G1). |
| ~~Bootstrap CSK auth chicken-and-egg~~ | n/a | n/a | Removed: tofu state backend uses R2 (static keys), not OCI S3-compat. OCI provider auths via SecurityToken/WIF (no CSK needed). The CSK is created fresh by the first apply and consumed only by downstream workflows that read it from tfstate. |
| CI orchestration race (regen-images runs before omni-host has token) | medium | new images carry stale/empty token | regen-images workflow precondition: `omnictl get connectionparams` returns non-empty `siderolink.api`; wait up to 5 min, fail fast otherwise. |
| Cross-layer state read (00-omni-server → 02-oracle-infra/bwire) fails | low | 00-omni-server apply fails | Verify tofu-apply orchestrator's layer-order respects new dep; relabel layer if needed. |
| OCI security list misconfigured (WG/SideroLink ports) | medium | nodes can't dial in; admin can't WG | Module's security list defines all ingress rules from day one. Smoke-tested per Gate G14. |
| Talos schematic missing OCI-arm64 | low | OCI nodes can't reinstall | `talos-images.yaml` already has both arches; PR diff just flips URL prefix. |
| OCI image-import doesn't trust new bucket URL | low | image-import fails | Bucket created `access_type = "ObjectRead"` (anonymous GET); URL shape identical to alimbacho67's. |
| DNS TTL stickiness | low | brief reachability gap | TTL 1 / 300 (proxied / direct). 5-min worst case. |
| Instance-attached IPv6 unstable across destroy+recreate | low | AAAA churns on VM rebuild | OCI doesn't expose "reserved IPv6" the way it does for IPv4 — the IPv6 is allocated to the VNIC from the VCN's /64 and is stable while the instance exists. AAAA records are tofu-managed off the VNIC's `ipv6addresses` attribute, so they auto-update on VM rebuild. Mitigation: avoid destroy+recreate of the omni-host VM unless absolutely necessary (cloud-init updates ride the instance lifecycle without recreate). |

### Rollback

Greenfield posture: rollback = "fix and re-run". Specifics:

1. 00-omni-server fails → `tofu destroy` on the layer, debug via OCI console serial-output, fix, re-apply.
2. Cluster doesn't bootstrap after labels reconcile → `omnictl get machines`, identify unbound, fix inventory in R2, re-trigger `sync-machine-labels`.
3. CSK breaks → re-mint in OCI console, update GH secrets, taint the resource, apply.
4. Worst case (Omni master keys lost / cluster wedged) → destroy + recreate. No consequence.

## Test plan / verification gates

| Gate | Command | Pass condition |
|---|---|---|
| G1: OCI Always-Free quota free (pre-merge) | `oci limits utilization-summary list --service-name compute --compartment-id <bwire>` | ARM A1.Flex shows ≥4 OCPU + ≥24 GB available |
| G2: bwire bootstrap CSK works (pre-merge) | `aws --endpoint <bwire-s3-compat> s3 ls` | Lists buckets without auth error |
| G3: 02-oracle-infra apply | `aws s3 ls --endpoint <bwire-s3-compat> s3://cluster-image-registry`; `oci compute instance get --instance-id <oci-bwire-node-1>` | Bucket exists, empty; oci-bwire-node-1 RUNNING |
| G4: alimbacho67 bucket gone | `aws s3 ls --endpoint <alimbacho67-s3-compat> s3://cluster-image-registry` | NoSuchBucket |
| G5: 00-omni-server apply | `curl -fsSL https://cp.stawi.org/healthz` | HTTP 200 |
| G6: New SideroLink token mintable | `omnictl get connectionparams -o json \| jq .spec.api_endpoint` | `https://cpd.stawi.org` |
| G7: regenerate-talos-images success | Auto-PR opened; `aws s3 ls s3://cluster-image-registry/<schematic>/<ver>/` | Both arm64 + amd64 artifacts present |
| G8: VMs reinstalled onto new images | `omnictl get machinestatus -l 'omni.sidero.dev/cluster=stawi'` | All 6 expected machines registered |
| G9: per-node ConfigPatches applied | `omnictl get configpatches -o table` | One per Contabo node, label-selector by `name=<n>` |
| G10: Machine labels reconciled | `omnictl get machinestatus <each> -o yaml` | `metadata.labels` carries role + name |
| G11: MachineSet binding | `omnictl get machineset -o table` | cp 1/1, workers 5/5 |
| G12: Cluster bootstrap | `omnictl kubeconfig stawi -f /tmp/kc && kubectl get nodes` | 6 nodes Ready |
| G13: prod.stawi.org LB DNS | `dig +short A prod.stawi.org` | 3 A records (alimbacho67 + brianelvis33 + contabo-bwire-1) |
| G14: WG admin SSH path | `wg-quick up admin && ssh oci-bwire-omni`; `ssh cp.stawi.org` (public) | WG path reachable; public path refused |
| G15: etcd-backup-s3 flowing | `aws s3 ls s3://omni-backup-storage/` after first hour | At least one snapshot object |

## Out of scope

- Track B — R2 → OCI tofu state migration (`cluster-tofu-state` → `cluster-state-storage`). Separate brainstorm/spec.
- On-prem tindase node — left alone.
- HA Omni / multi-CP. Single-CP architecture (single OCI bwire node) deliberate; HA is a future project once cross-provider etcd peering is solved (KubeSpan or equivalent).
- Cloudflare Worker for `pkgs.stawi.org` — follow-up after bucket move.

## Open questions

None — all decisions locked.

## Next

Implementation plan via `superpowers:writing-plans` skill, saved to `docs/superpowers/plans/2026-05-02-omni-oci-realignment-plan.md`.
