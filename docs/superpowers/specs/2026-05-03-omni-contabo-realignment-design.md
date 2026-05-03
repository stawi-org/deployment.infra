# Omni-on-Contabo cluster realignment — design

> **Status:** Design proposal — awaiting user review.
> **Date:** 2026-05-03
> **Supersedes:** [`2026-05-02-omni-oci-realignment-design.md`](./2026-05-02-omni-oci-realignment-design.md) — the OCI-centric realignment shipped in PR #156 and is the current production state. This spec moves omni + CP back to Contabo while keeping OCI bwire compute (consolidated to a single worker) and OCI buckets/IAM intact.
> **Scope:** Single PR + single cutover window. Greenfield posture (cluster degraded; no production state to preserve).

## Goal

Re-home the cluster's stable-IPv4-dependent components (omni-host + sole control-plane Talos node) on Contabo, while keeping OCI for in-cluster worker capacity. Consolidate OCI bwire compute to a single Always-Free worker. Build the omni-host module as a substrate-agnostic pair so future provider switches are a tfvar flip, not a code rewrite.

End-state in one PR:

- `omni-host` runs on Contabo VPS 202727781 (`contabo-bwire-node-3`), Ubuntu+Docker, non-cluster.
- Sole cluster CP runs on `contabo-bwire-node-2` (Talos), `NoSchedule` taint — no user workloads.
- All other VMs are workers: `contabo-bwire-node-1`, `oci-bwire-node-1`, `oci-alimbacho67-node-1`, `oci-brianelvis33-node-1`.
- OCI bwire compute consolidates from 2 small VMs (omni + CP, each 2/12/90) to 1 large VM (worker, 4/24/180 — full Always-Free ARM quota).
- LB pool = the 3 OCI workers (CF-proxied; CF absorbs OCI IPv4 churn).
- New `tofu/modules/omni-host-contabo/` parallels existing `omni-host-oci/`; both share template fragments via `tofu/shared/templates/omni-host/`.

## Why

PR #156 moved omni + CP to OCI bwire to consolidate plumbing. Operating that topology surfaced a substrate problem: **OCI public IPv4 is unstable for nodes that need to be dialled by stable name** (omni-host's `cp.stawi.org`, kube-apiserver). Reserved-IP quirks, ephemeral-IP churn on rebuild, and security-list misconfig blast radius (recent commits: ephemeral-IP switch, VCN/subnet sharing, gzip user_data hack) make OCI a poor fit for the central plane.

Contabo IPv4 is sticky across reinstalls (the node-contabo `null_resource.ensure_image` pattern relies on this). Moving omni + CP back to Contabo eliminates an entire class of public-DNS reachability issues without giving up the OCI-side wins from PR #156:

- All buckets stay in bwire — no storage rework.
- The bwire CSK stays — etcd-backup-s3 keeps writing to `omni-backup-storage`, just from the new Contabo omni-host.
- OCI bwire compute stays Always-Free, just reshaped to one beefy worker rather than two small VMs.

A new `omni-host-contabo` module (parallel, not a replacement) lets us flip back to OCI in the future via a tfvar — substrate decisions stop being load-bearing in code structure.

## Architecture (target end-state)

### Compute

| VM | Provider / VPS | Spec | Role | LB |
|---|---|---|---|---|
| `contabo-bwire-node-3` | Contabo VPS 202727781 | V94 (Ubuntu+Docker) | omni-host (non-cluster) | — |
| `contabo-bwire-node-2` | Contabo (Talos) | V94 | controlplane (NoSchedule) | no |
| `contabo-bwire-node-1` | Contabo (Talos) | V94 | worker | no |
| `oci-bwire-node-1` | OCI bwire | A1.Flex 4/24/180 | worker | **yes** |
| `oci-alimbacho67-node-1` | OCI alimbacho67 | A1.Flex (existing) | worker | **yes** |
| `oci-brianelvis33-node-1` | OCI brianelvis33 | A1.Flex (existing) | worker | **yes** |
| `onprem-tindase-node-1` | tindase | — | out of scope | — |

OCI bwire compute exactly fills the Always-Free ARM quota in a single VM (4 OCPU + 24 GB + 180 GB block volume).

Cluster topology: ControlPlane size 1, Workers size 4.

### Module structure

`tofu/modules/`:

- **`omni-host-contabo/` (new)** — Contabo-substrate omni-host. Adopts an existing Contabo VPS by ID, triggers in-place reinstall to Ubuntu via `null_resource.ensure_image` (same pattern as `node-contabo`), runs cloud-init from shared template. Outputs `public_ipv4`, `public_ipv6`, `etcd_backup_credentials`. Inputs include `vps_id`, `name`, plus the substrate-agnostic omni stack inputs (zone, omni version, WG keypair, CSK, …).
- **`omni-host-oci/` (existing)** — kept untouched modulo template extraction. Same outputs as `omni-host-contabo`.
- **`tofu/shared/templates/omni-host/`** (new) — shared fragments both modules `templatefile()`:
  - `docker-compose.yaml.tftpl` — fully substrate-agnostic.
  - `cert-bootstrap.sh.tftpl` — LE DNS-01 via Cloudflare API token, identical on both substrates.
  - `omni-backup.sh.tftpl` — hourly etcd-backup tarball uploader (Omni's own etcd-backup-s3 covers etcd; this is the broader `/etc/omni` + `/etc/letsencrypt` tarball).

`cloud-init.yaml.tftpl` stays **per-substrate** in each module's directory: OCI relies on the security list for ingress filtering, Contabo has no security-list concept and needs host `nftables` rules to filter the same set of ports. Each module's cloud-init writes the shared scripts to disk via `write_files`, sets up substrate-appropriate firewalling (or skips it for OCI), then starts the Docker compose stack.

The two modules differ in: instance + network resources (Contabo bare-VPS vs OCI VCN/subnet/security-list), and `cloud-init.yaml.tftpl` (firewall setup). Everything else (Docker, omni stack, cert flow, backup script) is shared.

### Provider switch in `00-omni-server`

`tofu/layers/00-omni-server/main.tf`:

```hcl
variable "omni_host_provider" {
  type    = string
  default = "contabo"
  validation {
    condition     = contains(["contabo", "oci"], var.omni_host_provider)
    error_message = "omni_host_provider must be 'contabo' or 'oci'"
  }
}

module "omni_host_contabo" {
  count  = var.omni_host_provider == "contabo" ? 1 : 0
  source = "../../modules/omni-host-contabo"
  # ...
}

module "omni_host_oci" {
  count  = var.omni_host_provider == "oci" ? 1 : 0
  source = "../../modules/omni-host-oci"
  # ...
}

locals {
  omni_host_ipv4 = coalescelist(
    module.omni_host_contabo[*].public_ipv4,
    module.omni_host_oci[*].public_ipv4,
  )[0]
  omni_host_ipv6 = coalescelist(
    module.omni_host_contabo[*].public_ipv6,
    module.omni_host_oci[*].public_ipv6,
  )[0]
}
```

Downstream (DNS module, `regenerate-talos-images.yml` reading omni endpoint, etc.) consumes `local.omni_host_ipv4` / `_ipv6` — fully substrate-agnostic.

### Storage / IAM

**No change** from PR #156. All four buckets (`cluster-state-storage`, `cluster-vault-storage`, `cluster-image-registry`, `omni-backup-storage`) live in bwire. The bwire CSK (`oci-operator-csk.tf`, output `omni_backup_writer_credentials`) is consumed by the new Contabo omni-host for `--etcd-backup-s3` writes — read from `02-oracle-infra` tfstate via `terraform_remote_state`, identical plumbing to today.

### Network

- DNS `cp.stawi.org` (orange-cloud, proxied) + `cpd.stawi.org` (gray-cloud, direct) re-target Contabo `bwire-3`'s sticky IPv4 / IPv6.
- WireGuard admin listener on `bwire-3` (UDP 51820). Contabo VPS doesn't have a security-list concept; relies on the host's nft rules (cloud-init brings them up).
- SSH on `bwire-3`: closed to public after Phase D verification (`ssh_enabled` toggle, same pattern as the deleted `omni-host` module pre-PR-156).

### Cluster spec

- ControlPlane MachineSet: size 1, `machineClass: cp` (selector: `role=controlplane`).
- Workers MachineSet: size 4, `machineClass: workers` (selector: `role=worker`).
- CP node carries the standard Kubernetes control-plane taint (`node-role.kubernetes.io/control-plane:NoSchedule`) — applied via Talos config patch on the CP machine.
- Per-node ConfigPatches for each Contabo cluster node (label-targeted `omni.sidero.dev/cluster=stawi` + `node.antinvestor.io/name=<n>`) carry `LinkAliasConfig`, `LinkConfig`, `HostnameConfig` — unchanged mechanism from PR #156, just two Contabo cluster nodes now (bwire-1, bwire-2) instead of three.

### Load-balancer targets (`prod.stawi.org` A/AAAA round-robin)

`node.kubernetes.io/external-load-balancer: "true"` set on:
- `oci-bwire-node-1`
- `oci-alimbacho67-node-1`
- `oci-brianelvis33-node-1`

CP and the Contabo worker carry `false`. CP doesn't need toleration gymnastics — no LB role on it.

## Decisions taken

| # | Decision | Choice |
|---|---|---|
| 1 | omni-host substrate revival | **Fresh `tofu/modules/omni-host-contabo/`**, parallel to `omni-host-oci/`, sharing templates. Both modules coexist; layer picks via `var.omni_host_provider`. |
| 2 | OCI bwire compute consolidation | **Destroy both `oci-bwire-omni` + `oci-bwire-node-1`, recreate `oci-bwire-node-1` fresh at 4/24/180.** Greenfield-clean; cluster reinstalls every node this PR anyway. |
| 3 | LB pool composition | **3 OCI workers** (`bwire-node-1`, `alimbacho67-node-1`, `brianelvis33-node-1`). All behind CF orange-cloud — CF absorbs OCI IPv4 churn. CP and Contabo worker stay out of the LB rotation. |
| 4 | CP workload exclusion | **Standard `node-role.kubernetes.io/control-plane:NoSchedule` taint** on CP. No LB role on CP, so no toleration issues. |
| 5 | Storage / IAM | **No change.** All buckets stay in bwire; CSK stays. Only `--etcd-backup-s3` writer client changes (OCI omni-host → Contabo omni-host), reading the same CSK from tfstate. |
| 6 | bwire-3 image transition | **Talos worker → Ubuntu via Contabo API in-place reinstall.** `null_resource.ensure_image` flips the image-id from Talos schematic to Ubuntu LTS; VPS itself never destroyed (per Contabo no-destroy rule). |
| 7 | Cutover sequencing | **A — Single-PR, single-window cutover.** Greenfield posture permits no dual-run. |
| 8 | Onprem tindase | Out of scope. |

## Components diff

### New tofu / module code

| Path | Purpose |
|---|---|
| `tofu/modules/omni-host-contabo/main.tf` | Contabo VPS adoption + `null_resource.ensure_image` (Ubuntu LTS reinstall) + cloud-init via shared template. Reads VPS ID, name, omni stack inputs. Outputs `public_ipv4`, `public_ipv6`, `etcd_backup_credentials`. |
| `tofu/modules/omni-host-contabo/variables.tf` | Inputs (substrate-specific: `vps_id`, `name`; substrate-agnostic: `cluster_zone`, `omni_version`, `wireguard_*`, `csk_*`, `etcd_backup_bucket`, …). |
| `tofu/modules/omni-host-contabo/outputs.tf` | Identical contract to `omni-host-oci`'s outputs. |
| `tofu/modules/omni-host-contabo/versions.tf` | contabo + cloudflare providers (no oracle here). |
| `tofu/shared/templates/omni-host/docker-compose.yaml.tftpl` | Extracted from `omni-host-oci`. Both modules `templatefile()` from this path. |
| `tofu/shared/templates/omni-host/cert-bootstrap.sh.tftpl` | LE DNS-01 cert flow, extracted. |
| `tofu/shared/templates/omni-host/omni-backup.sh.tftpl` | Hourly tarball uploader for `/etc/omni` + `/etc/letsencrypt`, extracted. |
| `tofu/modules/omni-host-contabo/cloud-init.yaml.tftpl` | Per-substrate cloud-init: installs Docker, sets up host nftables (Contabo has no security-list), writes shared scripts via `write_files`, runs `docker compose up`. |

### Modified tofu

| Path | Change |
|---|---|
| `tofu/layers/00-omni-server/main.tf` | Add `var.omni_host_provider` (default `"contabo"`). Replace single `module "omni_host_oci"` with the conditional pair (`omni_host_contabo` + `omni_host_oci`, each `count`-gated). Replace direct `module.omni_host_oci.ipv4` / `ipv6` references with `local.omni_host_ipv4` / `_ipv6`. |
| `tofu/layers/00-omni-server/outputs.tf` | `omni_host_instance_id` derived from whichever module is active (use `try()` or `coalescelist`). |
| `tofu/layers/00-omni-server/variables.tf` | New `omni_host_provider` variable; new `omni_host_contabo_vps_id` (default `"202727781"`). |
| `tofu/layers/00-omni-server/terraform.tfvars` | Set `omni_host_provider = "contabo"`. |
| `tofu/modules/omni-host-oci/docker-compose.yaml.tftpl` | **Deleted** (moved to shared). |
| `tofu/modules/omni-host-oci/cloud-init.yaml.tftpl` | Stays per-substrate — OCI cloud-init keeps its own copy (no nftables setup; relies on OCI security list). Updates `write_files` to embed shared `cert-bootstrap.sh` and `omni-backup.sh` rendered via `templatefile()`. |
| `tofu/modules/omni-host-oci/main.tf` | `templatefile()` paths for `docker-compose` flipped to shared. No behavioural change. |
| `tofu/layers/02-oracle-infra/<bwire compute>` | Drop OCI omni-host VM resources (handled here, not in `00-omni-server`, since omni-host is no longer on OCI for the active config). `oci-bwire-node-1` resource: `shape_config` bumps to 4 OCPU / 24 GB; `boot_volume_size_gb = 180`. |
| `tofu/layers/01-contabo-infra/imports.tf` (or bootstrap) | Remove VPS 202727781 from cluster-node imports. |
| `tofu/shared/bootstrap/contabo-instance-ids.yaml` | Remove `contabo-bwire-node-3`. (`bwire-1` and `bwire-2` stay.) |
| `tofu/shared/clusters/main.yaml` | `Workers.machineClass.size: 5 → 4`. ControlPlane stays 1. |
| `tofu/shared/clusters/per-node-patches.yaml.tmpl` | No structural change; the workflow now renders 2 patches (bwire-1, bwire-2) instead of 3. |
| `tofu/shared/inventory/talos-images.yaml` | No change — bucket already in bwire. |

### R2 inventory mutations

| R2 key | Change |
|---|---|
| `production/inventory/oracle/bwire/nodes.yaml` | Remove any standalone omni entry. `oci-bwire-node-1`: `lb` flips `false → true`. Spec field (if present) updates to 4/24/180. |
| `production/inventory/contabo/bwire/nodes.yaml` | **Remove** `bwire-3` (it leaves the cluster pool — it's adopted by `00-omni-server` as omni-host). `bwire-2`: role `worker → controlplane`. `bwire-1`: role stays `worker`, `lb: false` (no change). |
| `production/inventory/oracle/alimbacho67/nodes.yaml` | Verify `lb: true`. (Already true post-PR-156, just confirm.) |
| `production/inventory/oracle/brianelvis33/nodes.yaml` | Verify `lb: true`. |

### Deleted

- `tofu/modules/omni-host-oci/docker-compose.yaml.tftpl` — moved to shared templates path. (Module + its per-substrate `cloud-init.yaml.tftpl` retained.)

## Data flow during cutover

### Pre-merge (operator, ~5 min)

- Confirm Contabo VPS 202727781 is reachable and currently running Talos (post-PR-156).
- Confirm OCI bwire Always-Free quota is currently held by `oci-bwire-omni` + `oci-bwire-node-1` (will be freed and re-claimed in apply).
- Mutate R2 inventories (one-shot operator script using the existing `patch-inventory-node` workflow): remove `bwire-3` from contabo bwire, flip `bwire-2` role to controlplane, set OCI LB labels.
- Bump `force_reinstall_generation` in `01-contabo-infra/terraform.tfvars` and `02-oracle-infra/terraform.tfvars` so post-apply rolls every cluster node onto a freshly-built image carrying the new SideroLink token.

### Apply phase 1 — `02-oracle-infra` matrix run (parallel cells)

- **bwire cell**: `oci-bwire-omni` destroyed. `oci-bwire-node-1` destroyed and recreated at 4/24/180 (boots Talos maintenance, awaits Omni). Buckets + CSK unchanged.
- **alimbacho67 / brianelvis33 / ambetera cells**: no compute change.

### Apply phase 2 — `01-contabo-infra`

- `bwire-3` removed from cluster inventory → `node-contabo` resources for it destroyed (VPS itself untouched per Contabo no-destroy rule). Talos uninstalls on next reinstall.
- `bwire-2` role flips to controlplane.
- Force-reinstall generation bump rolls all 3 Contabo VPSes onto new Talos images.

### Apply phase 3 — `00-omni-server`

- `var.omni_host_provider = "contabo"` selects `module.omni_host_contabo`.
- Module adopts VPS 202727781, triggers Contabo API in-place reinstall to Ubuntu LTS image, runs cloud-init from shared templates.
- Omni stack starts with **fresh master keys + new SideroLink token**. LE cert minted via DNS-01.
- DNS `cp.stawi.org` (orange-cloud), `cpd.stawi.org` (gray-cloud) flip to bwire-3 IPv4/IPv6.
- End of phase 3: `https://cp.stawi.org/healthz` returns 200.

### Auto-trigger — `regenerate-talos-images.yml`

- Path-triggered by schematic-related changes (or `workflow_dispatch force=true`).
- Reads new SideroLink token from `cpd.stawi.org` via `omnictl`.
- Builds Talos images (Contabo x86, OCI ARM) with embedded token.
- Uploads to bwire `cluster-image-registry`.
- Opens auto-PR with new image checksums in `tofu/shared/inventory/talos-images.yaml`.

### Auto-PR merge — second tofu-apply

- **`02-oracle-infra` (bwire cell)**: `oci-bwire-node-1` reinstalls onto new image, registers with Omni.
- **`02-oracle-infra` (alimbacho67/brianelvis33)**: same.
- **`01-contabo-infra` (bwire-1, bwire-2)**: reinstall onto new images, register with Omni.

### Auto-trigger — `sync-cluster-template.yml`

- Path-triggered by `tofu/shared/clusters/**` changes.
- Applies `machine-classes.yaml`, `main.yaml` (Workers size 4).
- Renders per-node ConfigPatches for bwire-1, bwire-2 from each Contabo tfstate; `omnictl apply`.
- Applies `etcd-backup-s3-configs.yaml.tmpl` rendered from bwire CSK.

### Apply phase 4 — `03-talos`

- Machine-labels reconciler applies `MachineLabels` per node.
- Labels stick → MachineClass selectors match → Machines bind:
  - `contabo-bwire-node-2` → `cp` MachineSet
  - 4 worker-labelled machines → `workers` MachineSet
- etcd boots on `contabo-bwire-node-2`; kube-apiserver Ready; workers join.

End state: 1 CP + 4 workers Ready, `prod.stawi.org` round-robins across the 3 OCI LB nodes (CF-proxied), Omni dashboard at `cp.stawi.org`, etcd-backup-s3 hourly snapshots flowing.

## Risks + rollback

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| `bwire-3` reinstall flow Talos→Ubuntu fails | medium | omni doesn't come up | `null_resource.ensure_image` is the same pattern `node-contabo` uses for cross-image reinstalls; tested in PR #156's reverse direction. Smoke-test image flip locally before merge. |
| Window of omni unavailability between phase 1 (OCI omni destroyed) and phase 3 (Contabo omni up) | high (~10–20 min) | cluster control plane unreachable; in-flight Omni operations fail | Acceptable — cluster is degraded already; operator coordinates apply window. |
| Shared template extraction breaks `omni-host-oci` runtime | low | OCI substrate broken if we ever flip back | Mitigation: move templates first as a no-op refactor; verify `omni-host-oci` plan is clean before adding `omni-host-contabo`. |
| Contabo IPv4 sticky assumption wrong on this VPS | very low | DNS flip points to wrong IP | VPS 202727781 has held the same IPv4 across all PR-156 reinstalls; tofu-managed DNS would auto-correct on next apply if it ever changed. |
| OCI bwire `oci-bwire-node-1` recreate at 4/24/180 hits Always-Free quota issues | low | apply fails | Pre-merge `oci limits utilization-summary list` check confirms 4 OCPU + 24 GB available after destroy of the two existing VMs. |
| Missed reference to old single `module.omni_host_oci` somewhere in the layer | medium | plan/apply error | Grep audit before merge: `grep -rn "module.omni_host_oci" tofu/layers/00-omni-server/` returns only the new conditional + the local `coalescelist`. |
| force-reinstall generation bump misses bwire-3 (now non-cluster) | low | bwire-3 doesn't reinstall to Ubuntu | bwire-3's reinstall is owned by `omni-host-contabo` `null_resource.ensure_image`, triggered by the Ubuntu image-id input regardless of generation counter. Independent path. |

### Rollback

Greenfield-degraded posture: rollback = "fix and re-run". Specifics:

1. **`02-oracle-infra` fails**: re-target the failing cell, fix, re-apply. OCI bwire's two pre-existing VMs are already destroyed at this point — no clean-revert path. Only forward.
2. **`01-contabo-infra` fails**: bwire VPSes are reinstall-in-place; just re-trigger the apply with the right image. Talos comes back up.
3. **`00-omni-server` fails**: bwire-3's Ubuntu install partial → `tofu destroy -target=module.omni_host_contabo` (only destroys tofu state, VPS untouched), fix module, re-apply. Worst case operator dials the Contabo API directly to reset the VPS.
4. **Cluster doesn't bootstrap**: `omnictl get machines`, identify unbound, fix R2 inventory, re-trigger `sync-machine-labels`. Same playbook as PR #156.
5. **Existential**: revert this PR, set `omni_host_provider = "oci"`, re-apply — that's the whole point of the parallel-modules architecture.

## Test plan / verification gates

| Gate | Command | Pass condition |
|---|---|---|
| G1: OCI bwire Always-Free quota free post-destroy (mid-apply) | `oci limits utilization-summary list --service-name compute --compartment-id <bwire>` | After phase 1 destroys old VMs, ARM A1.Flex shows ≥4 OCPU + ≥24 GB available |
| G2: `oci-bwire-node-1` recreated at 4/24/180 | `oci compute instance get --instance-id <new id>` | shape_config shows 4 OCPU / 24 GB; boot volume 180 GB; status RUNNING |
| G3: Contabo bwire-3 reinstalled to Ubuntu | `ssh ubuntu@<bwire-3 IP>` (during the WG-only window: via WG) | Ubuntu LTS prompt; `docker compose ps` shows omni stack running |
| G4: Omni dashboard reachable at new IP | `curl -fsSL https://cp.stawi.org/healthz` | HTTP 200; CF returns origin from bwire-3 IP |
| G5: New SideroLink token mintable | `omnictl get connectionparams -o json \| jq .spec.api_endpoint` | `https://cpd.stawi.org` |
| G6: regenerate-talos-images success | Auto-PR opened; `aws s3 ls s3://cluster-image-registry/<schematic>/<ver>/` | Both arm64 + amd64 artifacts present |
| G7: All 5 cluster machines registered | `omnictl get machinestatus -l 'omni.sidero.dev/cluster=stawi'` | bwire-1, bwire-2, oci-bwire-node-1, oci-alimbacho67-node-1, oci-brianelvis33-node-1 |
| G8: Per-node ConfigPatches applied | `omnictl get configpatches -o table` | One per Contabo cluster node (bwire-1, bwire-2), label-selector by name |
| G9: MachineSet binding | `omnictl get machineset -o table` | cp 1/1, workers 4/4 |
| G10: CP NoSchedule taint | `kubectl get node contabo-bwire-node-2 -o jsonpath='{.spec.taints}'` | Shows `node-role.kubernetes.io/control-plane:NoSchedule` |
| G11: Cluster bootstrap | `omnictl kubeconfig stawi -f /tmp/kc && kubectl get nodes` | 5 nodes Ready |
| G12: prod.stawi.org LB DNS | `dig +short A prod.stawi.org` | 3 A records (the 3 OCI workers, all CF-proxied so values are CF anycast — verify via direct gray-cloud `cpd` analogue or Cloudflare API) |
| G13: WG admin SSH path to bwire-3 | `wg-quick up admin && ssh contabo-bwire-node-3` | Reachable; public SSH refused after Phase D toggle |
| G14: etcd-backup-s3 flowing | `aws s3 ls s3://omni-backup-storage/` after first hour | At least one snapshot |
| G15: Substrate switch dry-run | `tofu -chdir=tofu/layers/00-omni-server plan -var omni_host_provider=oci` | Plan succeeds (proves the OCI path is still wired); plan shows destroy of contabo + create of oci VM (don't apply) |

## Out of scope

- Track B — R2 → OCI tofu state migration (`cluster-tofu-state` → `cluster-state-storage`). Separate brainstorm/spec.
- On-prem tindase node — left alone.
- HA Omni / multi-CP. Single-CP architecture deliberate; HA is a future project once cross-provider etcd peering is solved.
- Cloudflare Worker for `pkgs.stawi.org` — follow-up.
- Generalising `node-contabo` and `node-oracle` into a shared `node-base` module — not driven by this work.

## Open questions

None — all decisions locked.

## Next

Implementation plan via `superpowers:writing-plans` skill, saved to `docs/superpowers/plans/2026-05-03-omni-contabo-realignment-plan.md`.
