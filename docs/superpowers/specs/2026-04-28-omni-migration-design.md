# Omni Migration Design

> **Status:** Design proposal — awaiting approval before implementation plan.
> **Date:** 2026-04-28
> **Cluster name (new, Omni-managed):** `stawi-cluster`
> **Omni host:** `cluster-omni-contabo` (single Contabo VPS, Ubuntu 24.04, NOT a cluster)
> **Cluster name (old, retired post-cutover):** `antinvestor-cluster`
> **Omni licensing posture:** BSL self-hosted, non-production use (option iii)
> until org generates revenue justifying a Sidero support contract or a
> migration to SaaS.

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
                │   cp.antinvestor.com  │  (orange-cloud A/AAAA)
                │   cp.stawi.org        │  (orange-cloud A/AAAA)
                └───────────┬───────────┘
                            │ CF Tunnel (outbound only;
                            │ no inbound port on the VM)
                            ▼
        ┌──────────────────────────────────────────────────┐
        │  cluster-omni-contabo                            │
        │  (was contabo-bwire-node-3)                      │
        │                                                  │
        │  Single Contabo VPS. Ubuntu 24.04 LTS Minimal    │
        │  from Contabo's official image catalog. NO ssh   │
        │  shell logins ever — all configuration lives     │
        │  in the tofu-rendered cloud-init drop-in below.  │
        │                                                  │
        │  cloud-init (idempotent, source of truth):       │
        │    • install Docker engine + compose plugin      │
        │    • render /etc/omni/docker-compose.yaml        │
        │    • render systemd units:                       │
        │        - omni-stack.service       (compose up)   │
        │        - omni-backup.{service,timer} (hourly →R2)│
        │        - cloudflared.service      (tunnel agent) │
        │    • render /etc/omni/.env (sopsed at rest in    │
        │      this repo, decrypted at provision time)     │
        │    • iptables/nftables: DROP all inbound except  │
        │      established/related; CF Tunnel is outbound  │
        │      only and is the sole control-plane ingress  │
        │    • unattended-upgrades on, security patches    │
        │      auto-installed                              │
        │                                                  │
        │  Containers (managed by docker-compose):         │
        │    • ghcr.io/siderolabs/omni:<pinned>            │
        │    • ghcr.io/dexidp/dex:<pinned>                 │
        │    • cloudflare/cloudflared:<pinned>             │
        │                                                  │
        │  Persistent state on /var/lib/omni:              │
        │    • Omni's sqlite store                         │
        │    • Dex config + state                          │
        │    Hourly snapshot → R2 via systemd timer        │
        └──────────────────────────────────────────────────┘
                            ▲
                            │ SideroLink (always-outbound from
                            │ stawi-cluster nodes; no inbound
                            │ ports anywhere)
                            │
            ┌───────────────┼─────────────────┐
            ▼               ▼                 ▼
       contabo-bwire-   oci-* (OCI)      tindase (on-prem)
       node-{1,2}       VMs              VM
       Talos +          Talos +          Talos +
       siderolink-      siderolink-      siderolink-
       agent            agent            agent
                — members of stawi-cluster —
                  managed entirely by Omni
```

### Component summary

| Component | Where | What |
|---|---|---|
| `cluster-omni-contabo` | Single Contabo VPS, Ubuntu 24.04 LTS | Plain VM (NOT a k8s cluster). All config from tofu-rendered cloud-init; idempotent; no SSH-driven setup |
| Omni container | docker-compose on the VM | API + UI; sqlite-backed; pinned image, upgrades = bump version in tofu and re-apply |
| Dex container | docker-compose on the VM | OIDC proxy; brokers `stawi-org` GitHub App auth into Omni |
| cloudflared container | docker-compose on the VM | Outbound-only CF Tunnel; the only ingress to the VM |
| Backup systemd timer | on the VM | Hourly: `sqlite3 .backup` + `rclone copy` to R2 |
| `stawi-cluster` (multi-node) | Contabo + OCI + on-prem | Production cluster; nodes boot Talos+siderolink-agent, register with Omni |
| Tofu | provisions VPSes/instances + the omni-host VM via cloud-init | No more Talos config rendering; one entry in inventory per node |
| Operator + CI | laptop, GH Actions | `omnictl` and browser → CF → Omni; kubeconfig delivered with OIDC binding |

### Why "plain VM with cloud-init", not Ubuntu-and-SSH-in-to-configure

The earlier objection ("don't configure Ubuntu 24.04 manually") was about the operational shape — bespoke commands run by hand, drifty state, tribal knowledge. This design avoids that entirely:

- **Single source of truth.** Every byte of config is in `tofu/modules/omni-host/cloud-init.yaml.tftpl`. Reading the tofu repo tells you exactly what's running on the VM.
- **Disposable.** `tofu destroy && tofu apply` rebuilds the VM bit-for-bit from declarative state. Recovery from corruption is "snapshot the sqlite DB → reprovision → restore snapshot".
- **No SSH access path needed for ops.** SSH is allowed *only* during cloud-init (to inject the initial config), then either denied entirely or restricted to operator break-glass key.
- **Pinned image versions.** Container tags pinned by digest in tofu vars; updates are a deliberate `talos_version`-style bump.
- **Automatic security patches.** `unattended-upgrades` keeps the base OS current without operator intervention.

This is the simplest production-grade setup that doesn't reach for k8s. K8s-on-the-omni-host is on the roadmap if HA Omni becomes worth the complexity; not today.

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
| `tofu/layers/03-omni-cluster/` | **new (~80 lines)** — uses the [terraform-provider-omni](https://github.com/siderolabs/terraform-provider-omni) to declare the `stawi-cluster` template (talos_version, kubernetes_version, CNI, machine-class assignment rules, role labels). Depends on the omni-host being up. |
| `tofu/layers/04-flux/` | **stays** — pulls kubeconfig from `tofu/layers/03-omni-cluster` (Omni issues it after the cluster bootstraps) instead of from `03-talos` |
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

**No new hardware.** Existing Contabo VPSes + OCI instances + on-prem VM are reimaged in place. Cost: a one-time downtime window from the moment node-3's reinstall begins until `stawi-cluster` has etcd quorum + apiserver — expected 30–90 min if nothing surprises us.

The existing cluster is already partially down (OCI nodes stuck in maintenance, several PRs of debug today). Tearing it down hard is not a meaningful regression.

1. **Stage the new schematic + tofu code** (no destructive change yet):
   - Add `siderolabs/siderolink-agent` to `tofu/shared/schematic.yaml`.
   - Bump `force_image_generation` (Contabo + OCI) so the next apply rebuilds images.
   - Land the new tofu module: `omni-host` (Ubuntu Contabo VPS + tofu-rendered cloud-init that brings up the omni/dex/cloudflared docker-compose stack on first boot), the `00-omni-server` layer that instantiates it, and the `03-omni-cluster` layer (the Omni cluster template via terraform-provider-omni; its `tofu apply` runs *after* step 4 once Omni is reachable).
   - Plumb `omni_siderolink_url` through `node-contabo`, `node-oracle`, `node-onprem`. Don't apply yet.
2. **Pre-flip Cloudflare DNS** for `cp.antinvestor.com` and `cp.stawi.org` from gray-cloud A/AAAA (today: round-robin over Contabo CP public IPs) to orange-cloud A/AAAA targeting CF Tunnel ID. The tunnel doesn't exist yet, so the names temporarily resolve to a 502 from CF — that's fine; the old cluster is being torn down anyway.
3. **Tear down `antinvestor-cluster`**: drop tofu state for `00-talos-secrets`, `03-talos`. Contabo CPs continue to run Talos but are unmanaged; etcd quorum stays intact briefly. (Don't drain workloads yet — Flux on those nodes will be wiped in step 6.)
4. **Reinstall contabo-bwire-node-3 → cluster-omni-contabo** via Contabo's API: switch the OS image from Talos (current) to Ubuntu 24.04 LTS Minimal (or Alpine), apply cloud-init that:
   - installs `omni` server (systemd unit, omni binary from siderolabs releases),
   - installs `cloudflared` (systemd unit, registers a new tunnel under the existing Cloudflare account),
   - tells `cloudflared` to expose `:443` (HTTPS for Omni UI/API) and the SideroLink UDP port,
   - configures GitHub OIDC against `stawi-org`,
   - sets up the hourly etcd-snapshot CronJob targeting R2,
   - drops iptables to DENY all inbound except localhost.
5. **Verify** `https://cp.antinvestor.com` resolves, GitHub OIDC login works, Omni dashboard loads. Generate the `stawi-cluster` join token; record under SOPS in inventory.
6. **Reinstall the rest** with the new Talos+siderolink-agent image. Order is: 2 Contabo CPs → OCI workers → on-prem. Each reinstall is the existing `force_reinstall_generation` / `reinstall-request-file` path; the new user_data adds `siderolink.api=https://cp.antinvestor.com?jointoken=<token>` to the kernel cmdline. Each VM, on first boot, dials home, registers as a Machine, gets auto-allocated to `stawi-cluster`, gets its config pushed by Omni.
7. **Apply `03-omni-cluster`**: defines the cluster template, role assignments, machine class rules. Omni rolls the cluster up; etcd bootstraps; kube-apiserver Ready.
8. **Repoint Flux** to `stawi-cluster`. Workloads redeploy. Verify.
9. **Cleanup PR**: delete `00-talos-secrets/`, `03-talos/`, `cluster-{reset,reinstall}.yml`, `tofu-reconstruct.yml`, `node-recovery.yml`, `cluster-health.yml` (replace with a one-liner curl), `talos-apply-or-upgrade.sh`, `cluster-health.sh`, KubeSpan patch.

Downtime window covers steps 3–7. No production user traffic flows through the cluster currently (nothing deployed beyond a hello workload), so this is safe.

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
- **In-place adoption** of the existing `antinvestor-cluster` — won't try. Fresh cluster identity (`stawi-cluster`) on the same hardware via reimage.
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

None. All decisions locked, in-place reimage on existing hardware confirmed.

## What I'd write next

If approved, an implementation plan under `docs/superpowers/plans/2026-04-28-omni-migration-plan.md` covering:

- Task 1: Provision temporary Omni host (omni-tmp), install Omni, wire OIDC + CF Tunnel + R2 backup
- Task 2: Bump schematic with `siderolink-agent` extension, regenerate images per provider
- Task 3: Define `stawi-cluster` template via terraform-provider-omni in new layer 03-omni-cluster
- Task 4: Add `omni_siderolink_url` plumbing through node modules, drop machine-config rendering
- Task 5: Reimage existing cluster nodes (Contabo CPs, OCI workers, on-prem) onto the new schematic; nodes register with Omni and join `stawi-cluster`
- Task 6: Migrate Flux GitOps pointer
- Task 7: Decommission `antinvestor-cluster`
- Task 8: Final DNS flip + retire omni-tmp
- Task 9: Delete the now-dead workflows, layers, scripts (the cleanup PR)
