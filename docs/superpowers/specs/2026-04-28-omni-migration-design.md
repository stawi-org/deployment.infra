# Omni Migration Design

> **Status:** Design proposal — awaiting approval before implementation plan.
> **Date:** 2026-04-28
> **Cluster name (new):** `stawi-cluster`
> **Cluster name (old, retired post-cutover):** `antinvestor-cluster`

## Goal

Move cluster lifecycle management from this repo's bespoke tofu+talosctl rendering pipeline to **self-hosted Omni**. Omni manages: machine secrets, machine config rendering, version pinning, mesh networking (SideroLink), reset/reinstall flows, and operator-facing kubeconfig issuance.

## Why

Twelve hours of debug across PRs #23–#29 traced the same class of failures: Talos provider/SDK version mismatches, OCI image generation staleness, in-place vs destroy+create lifecycle confusion, and arch-specific maintenance-mode parser drift. None of these are *cluster* problems — they're tooling-pipeline problems Omni already solves.

Operating goal after migration: **adding a node = editing `nodes.yaml`**. Provisioning, image selection, secret distribution, cluster join, role assignment, kubeconfig delivery — Omni handles them.

## Architecture

```
                   PUBLIC INTERNET
                          │
              ┌───────────┴───────────┐
              │   Cloudflare anycast  │
              │                       │
              │   cp.antinvestor.com  │  (orange-cloud A/AAAA)
              │   cp.stawi.org        │  (orange-cloud A/AAAA)
              │                       │
              └───────────┬───────────┘
                          │  CF Tunnel (outbound from Omni host;
                          │  no inbound port on the Contabo VM)
                          ▼
        ┌──────────────────────────────────────┐
        │  cluster-omni-contabo                │
        │  (was contabo-bwire-node-3)          │
        │                                      │
        │  • Ubuntu 24.04 LTS Minimal          │
        │  • omni server (systemd unit)        │
        │  • cloudflared (systemd unit) —      │
        │    HTTPS to omni:443, UDP to         │
        │    siderolink-agent service port     │
        │  • embedded etcd for omni state      │
        │  • backup CronJob: hourly snap → R2  │
        │                                      │
        │  Public IP: present, all inbound     │
        │  iptables-DROPped. CF tunnel is the  │
        │  only ingress.                       │
        └──────────────────────────────────────┘
                          ▲
                          │ SideroLink (always-outbound from cluster
                          │ nodes; works behind NAT, no inbound port
                          │ required on any cluster node)
                          │
        ┌─────────────────┼──────────────────────┐
        │                 │                      │
        ▼                 ▼                      ▼
   contabo-bwire-      oci-* / tindase /     (future nodes)
   node-{1,2}          on-prem-*             same recipe
   (Talos +            (Talos +              (Talos +
    siderolink-         siderolink-           siderolink-
    agent ext)          agent ext)            agent ext)
```

### Component summary

| Component | Where | What |
|---|---|---|
| Omni server | `cluster-omni-contabo` | Stateful service, embedded etcd, GitHub OIDC, exposes API + UI |
| Cloudflare Tunnel | same VM | Outbound-only HTTPS+UDP relay, hides Omni's IP |
| Talos cluster | Contabo + OCI + on-prem | Boots Omni-aware images, dials home, never accepts inbound directly |
| Tofu provisioning | unchanged for VMs | Still creates VPSes/instances; just stops generating Talos config |
| Operator | laptop / CI | `omnictl` (CLI) and browser → CF → Omni; kubeconfig delivered with OIDC binding |

## Authentication

**GitHub OIDC** via the existing `stawi-org` GitHub App (already configured for Flux). Omni's OIDC config:

- **Issuer:** `https://token.actions.githubusercontent.com` for CI service accounts
- **Issuer:** `https://github.com/login/oauth` for human operator UI logins via the same app
- **Authorized GitHub orgs:** `stawi-org` (single org under the new naming)
- **Role mapping:** org members → `cluster-admin` for `stawi-cluster`; further granularity later

CI service accounts (e.g., the `tofu-apply` workflow needing to update cluster templates) use short-lived OIDC tokens minted per workflow run — no long-lived secret stored in GitHub Secrets.

## Persistence + backup

Omni's state store lives on the omni-server VM at `/var/lib/omni/`. Single-instance Omni uses an embedded bbolt store; HA Omni uses a shared etcd. We're starting single-instance, so bbolt — but `omnictl etcd snapshot` works the same for both.

**Backup CronJob** runs hourly on the omni-server:

```bash
omnictl ... etcd snapshot /tmp/omni-$(date +%s).db
aws s3 cp /tmp/omni-*.db s3://cluster-tofu-state/production/omni-backups/ \
  --endpoint-url https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com
```

R2 lifecycle policy retains 30 days. Snapshot size ~tens of MB. Cost negligible.

Restore path: stand up a fresh omni-server VM, `omnictl etcd restore <snapshot>`, point DNS, done.

## Repo layout — concrete diff

| Path | Action |
|---|---|
| `tofu/layers/00-talos-secrets/` | **delete** — Omni issues all secrets |
| `tofu/layers/00-omni-server/` | **new** — provisions cluster-omni-contabo, installs Omni via cloud-init, registers CF Tunnel, configures GitHub OIDC, sets up backup CronJob |
| `tofu/modules/omni-host/` | **new** — reusable module for the Omni VM (Contabo today; could be ported to OCI/onprem later) |
| `tofu/layers/01-contabo-infra/` | **stays** — VM provisioning. node-contabo gets `omni_siderolink_url` injected into kernel cmdline |
| `tofu/layers/02-oracle-infra/` | **stays** — same pattern; the `.oci`-archive metadata work from PR #23 carries over verbatim |
| `tofu/layers/02-onprem-infra/` | **stays** — same |
| `tofu/layers/03-talos/` | **delete entirely** — no more `data.talos_machine_configuration`, no `talos_machine_configuration_apply`, no `talos_machine_bootstrap`, no per-node config artifacts, no DNS pinning, no firewall patches |
| `tofu/layers/03-omni-cluster/` | **new (~80 lines)** — uses the [terraform-provider-omni](https://github.com/siderolabs/terraform-provider-omni) to declare the `stawi-cluster` template (talos_version, kubernetes_version, CNI, machine-class assignment rules, role labels) |
| `tofu/layers/04-flux/` | **stays** — pulls kubeconfig from `tofu/layers/03-omni-cluster` instead of `03-talos` |
| `tofu/shared/schematic.yaml` | gain `siderolabs/siderolink-agent` system extension |
| `tofu/shared/patches/*.yaml` | most → expressed as **Omni cluster config patches** instead of tofu-rendered patches; `kubespan.yaml` deleted (SideroLink replaces KubeSpan) |
| `tofu/modules/node-contabo/`, `node-oracle/`, `node-onprem/` | gain `omni_siderolink_url` variable; stops needing per-node Talos config files |
| `scripts/talos-apply-or-upgrade.sh` | **delete** |
| `scripts/cluster-health.sh` | **delete** — replaced by Omni's own healthcheck endpoint |
| `.github/workflows/cluster-{reset,reinstall}.yml` | **delete** — Omni dashboard / `omnictl machine reset` |
| `.github/workflows/tofu-reconstruct.yml` | **delete** |
| `.github/workflows/cluster-health.yml` | replaced with one-liner curl `cp.antinvestor.com/health` |
| `.github/workflows/node-recovery.yml` | **delete** |
| `.github/reconstruction/` | **delete** |
| `production/inventory/*/nodes.yaml` | **stays** — same shape; gains optional `cluster: stawi-cluster` field for which Omni cluster a node joins |

Net diff: roughly **−1500 / +500 lines.** The most fragile parts of the stack go away.

## Inventory-driven node-add flow

End state user experience:

```bash
# 1. Edit inventory
$ vi production/inventory/oracle/bwire/nodes.yaml
nodes:
  oci-bwire-node-2:               # NEW
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    cluster: stawi-cluster        # which Omni cluster

# 2. Push to R2 + open PR
$ ./scripts/seed-inventory.sh
$ git push

# 3. Merge → tofu-apply runs:
#    - 02-oracle-infra: oci_core_instance.this["oci-bwire-node-2"] CREATE
#      with kernel cmdline siderolink.api=https://cp.antinvestor.com?...
#    - 03-omni-cluster: no diff (cluster template unchanged; Omni
#      auto-allocates the new machine to the cluster on registration)
#
# Within ~60s of the VM booting, the machine appears in Omni UI as
# "Available", auto-allocator (configured per-cluster) accepts it.
# kubectl get nodes shows oci-bwire-node-2 Ready a couple of minutes
# later.
```

Reset/reinstall: button in Omni UI, or `omnictl machine reset oci-bwire-node-2`. No PR-based request file workflow.

## Cutover sequence

The repo currently has a partially-healthy cluster (3 Contabo nodes joined, OCI nodes stuck in maintenance). The cutover doesn't try to in-place adopt the existing cluster — Omni issues fresh secrets and CA, so adoption isn't possible across that boundary. **Greenfield** is the path.

1. **Stand up Omni at temporary `omni-tmp.antinvestor.com`** — orange-cloud, CF tunnel. Provision cluster-omni-contabo as a *new* small Contabo VPS (NOT yet repurposing node-3; that comes after the old cluster is gone). Install Omni, configure OIDC, generate cluster join token for `stawi-cluster`.
2. **Build the Omni-aware schematic.** Image factory rebuilds with `siderolink-agent` extension; `force_image_generation` bumps to invalidate gen10.
3. **Provision the `stawi-cluster` greenfield** alongside the old cluster: 2 new Contabo VPSes (CP duty), OCI VMs (re-imaged), on-prem VM. They boot the new schematic, dial home to Omni, get assigned to `stawi-cluster`.
4. **Migrate Flux GitOps state pointer** from old cluster's API to new. Workloads redeploy on the new cluster. Verify everything.
5. **Decommission `antinvestor-cluster`** — destroy old VMs, drop tofu state for layer 00-talos-secrets and 03-talos.
6. **Repoint `cp.antinvestor.com` and `cp.stawi.org`** orange-cloud entries from `omni-tmp` to the new canonical Omni endpoint. (Actually: easier to start them pointing at the new endpoint from step 1 once `stawi-cluster` is up.)
7. **Repurpose old contabo-bwire-node-3** into the eventual `cluster-omni-contabo`. (Alternative: retire it. Keep the temp Omni VPS as the permanent one. Saves the cutover step. **My pick.**)
8. **Retire `omni-tmp.antinvestor.com`** DNS + tunnel.

## Risks + mitigations

| Risk | Mitigation |
|---|---|
| Omni outage = no cluster-mgmt operations (cluster keeps running, but operator can't push config / reset / upgrade) | Hourly etcd snapshot to R2; rebuild path documented; consider HA (2-3 Omni replicas with shared etcd) post-launch |
| Single Contabo VPS for Omni is a SPOF | Mitigated by R2 backup; HA roadmap above |
| Cloudflare account compromise → CF Tunnel can be redirected | OIDC into Omni gates everything; CF compromise leaks traffic but not cluster admin |
| GitHub OIDC down → operator/CI can't sign into Omni | Local emergency admin keypair stored in 1Password / age-encrypted in repo; documented break-glass procedure |
| `siderolink-agent` extension breaks on Talos version bump | Stage upgrades on a single node first; Omni's rolling upgrade handles this naturally |
| The OCI maintenance-mode parser issue (this conversation's main pain) | Less relevant under Omni — Omni doesn't use `talosctl --insecure` config push; SideroLink delivers config via the agent which is built into the same image and version-aligned by definition |

## Non-goals for v1

- **HA Omni** — single instance to start. Etcd backups cover disaster recovery; HA is a follow-up.
- **Multiple clusters** — `stawi-cluster` only. Multi-cluster is a future Omni feature once volume justifies it.
- **In-place adoption** of the existing `antinvestor-cluster` — won't try. Greenfield + workload migration via Flux.
- **Self-hosted vs SaaS comparison** — locked on self-hosted given the answer in the conversation.
- **WireGuard-bastion / cluster-bastion VPN design** from earlier in the conversation — separate project; Omni's SideroLink covers operator-to-cluster connectivity for cluster ops; the bastion-for-talosctl use-case largely goes away. The home-egress-VPN piece is still relevant but unrelated to this design.

## Test plan

Per implementation phase:

1. **Omni-host bring-up** — `omni-tmp.antinvestor.com` reachable via browser → GitHub OIDC login succeeds → `omnictl get clusters` returns empty list.
2. **Schematic + extension** — A test VM boots from the new image and shows up as "Available" in Omni UI within 60s.
3. **stawi-cluster bootstrap** — Cluster template applies; nodes auto-allocate; `kubectl get nodes` shows all expected nodes Ready; etcd quorum healthy; flux check passes.
4. **Inventory-add flow** — Add a test worker to `nodes.yaml`, push, merge, verify it joins the cluster within 5 minutes without any manual step.
5. **Reset flow** — `omnictl machine reset <id>`; node disappears, returns to maintenance-mode-equivalent (siderolink awaiting reassignment), Omni reassigns it, node rejoins.
6. **Backup + restore drill** — Take a snapshot, simulate Omni-host loss (stop service, wipe etcd dir), restore from the latest R2 snapshot, verify all clusters and machines re-appear in Omni.
7. **DNS cutover** — Both `cp.antinvestor.com` and `cp.stawi.org` resolve via Cloudflare anycast; `dig +trace` does NOT reveal the Contabo VPS IP; `omnictl get clusters` works against either name.

## Open questions

**One sub-decision worth surfacing before plan-writing:**

You said *"install Omni on one of the contabo nodes and rename `contabo-bwire-node-3`"*. The cutover sequence above doesn't directly do that — it provisions a fresh Omni VPS first (so the new cluster has somewhere to register), then the old node-3 either:

- **(a) gets repurposed** into the permanent Omni host after the old cluster is gone (your stated intent — saves a VPS but adds a delicate step 7 where Omni's CF tunnel hostname temporarily moves between two VMs), or
- **(b) gets retired**, and the temporary Omni VPS becomes the permanent one (~€4/mo for a Contabo VPS-S forever; simpler cutover; node-3 just goes away with the rest of `antinvestor-cluster`).

I'd lean **(b)** for simplicity, but **(a)** is what you literally asked for. Your call.

## What I'd write next

If approved, an implementation plan under `docs/superpowers/plans/2026-04-28-omni-migration-plan.md` covering:

- Task 1: Provision temporary Omni host (omni-tmp), install Omni, wire OIDC + CF Tunnel + R2 backup
- Task 2: Bump schematic with `siderolink-agent` extension, regenerate images per provider
- Task 3: Define `stawi-cluster` template via terraform-provider-omni in new layer 03-omni-cluster
- Task 4: Add `omni_siderolink_url` plumbing through node modules, drop machine-config rendering
- Task 5: Provision new cluster nodes (greenfield)
- Task 6: Migrate Flux GitOps pointer
- Task 7: Decommission `antinvestor-cluster`
- Task 8: Final DNS flip + retire omni-tmp
- Task 9: Delete the now-dead workflows, layers, scripts (the cleanup PR)
