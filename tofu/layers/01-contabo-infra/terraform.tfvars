# tofu/layers/01-contabo-infra/terraform.tfvars
# Inventory is injected from the canonical R2 object at production/config/cluster-inventory.yaml.
contabo_accounts = {}

# ssh_public_key is injected via env var TF_VAR_ssh_public_key (from GitHub secrets or operator env).


# Cluster DNS (cp.* + cp-<N>.* round-robin + prod.* for LB-labelled
# nodes) is published by layer 03-talos, which has a global view of
# every CP across every provider. Zone configuration lives in that
# layer's terraform.tfvars — not here.

# Reinstalls (cluster-wide or per-node) are now driven by request
# files under .github/reconstruction/. The tofu-reconstruct workflow
# opens a PR with a reinstall-*.yaml file; merging it fires the
# cluster-reinstall workflow which dispatches tofu-apply, and the
# request hash flows into per-node trigger keys via reconstruction.tf.

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"


# Bump to force a fleet-wide Contabo VPS reinstall on next apply,
# regardless of image_id stability. Pairs with the same knob in
# 02-oracle-infra/terraform.tfvars; bump both together when rolling
# every cluster node (e.g. after the omni-host's /var/lib/omni was
# wiped, leaving the existing nodes' kernel-cmdline jointokens
# stale).
#
# Bump history:
#   2 — 2026-05-01: post-omni-host-state-wipe recovery. Existing
#                   nodes had stale jointokens; Omni rejected joins
#                   with `has_valid_join_token: false`. Forced
#                   reinstall onto fresh images carrying the current
#                   Omni's token.
#   5 — 2026-05-01: clean-slate reinstall after `omni-cluster-delete`
#                   + bulk `omni-machine-delete` cleared the stawi
#                   cluster and all zombie Machine UUIDs. Pairs with
#                   the wait-for-registration fix in layer 03's
#                   sync-machine-label.sh so post-reinstall labelling
#                   doesn't race the SideroLink phone-home.
#   6 — 2026-05-01: fleet-wide reinstall paired with the omni-host
#                   IPv6-forwarding fix landing on layer 00. Clean
#                   start for cluster nodes once cross-CP etcd peering
#                   actually works, so SideroLink Links are minted
#                   against an Omni that can forward.
#   8 — 2026-05-02: paired with the omni-host migration off Contabo
#                   onto OCI bwire (PR #156). New omni-host mints a
#                   fresh SideroLink token at first boot; bumping
#                   here rolls every Contabo VPS — including the
#                   freed bwire-3 (was 202727781 / Contabo omni-host)
#                   newly re-adopted by this layer — onto images
#                   carrying that new token.
#  11 — 2026-05-04: post cluster delete + recreate. Contabo nodes
#                   booted with Talos's Contabo-platform-default
#                   hostnames (vmi2727782/3) because the per-node
#                   link patches couldn't bind to running machines.
#                   Force-reinstall lets the patches apply at first
#                   boot, picking up canonical hostnames + static
#                   IPv4/IPv6 + LinkAliasConfig.
#  16 — 2026-05-06: re-introduce per-node LinkConfig with static v4
#                   + static v6 + dual gateways (v4 from API,
#                   fe80::1 v6 link-local) — required to satisfy
#                   kube-apiserver's family-match check for the
#                   IPv6-first dual-stack service range. Live-
#                   applying LinkConfig has broken Contabo nodes
#                   in the past (kernel half-state); the bump
#                   makes every Contabo VPS boot fresh into the
#                   new config from first boot. Paired with k8s
#                   v1.36.0 bump in shared/versions.auto.tfvars.json.
#  17 — 2026-05-06: vmi2727782 (CP) didn't boot after gen=16
#                   reinstall — Contabo API returned 200 OK but the
#                   VPS stayed unreachable on v4 / SideroLink and
#                   Omni held its old MachineID at BEFORE_DESTROY.
#                   Two contabo-reboot-vps cycles didn't recover.
#                   Bumping forces a fresh reinstall PUT against the
#                   Contabo image API; the in-place reinstall has
#                   sometimes raced its own tasks under the hood,
#                   and a follow-up bump has cleared similar stuck
#                   states before. vmi2727783 booted fine on gen=16,
#                   so the bump is per-VPS-redundant for it (PUT is
#                   idempotent on the image API).
#  18 — 2026-05-06: gen=17 hit Contabo IDP brute-force lockout on
#                   vmi2727782's parallel ensure_image attempt
#                   (HTTP 401 invalid_grant), even though
#                   vmi2727783's parallel attempt succeeded.
#                   KeyCloak's per-account lockout takes ~10 min
#                   to clear; this bump retries after the cooldown
#                   so the locked-out node finally re-reinstalls.
#  19 — 2026-05-07: storage volume layout (EPHEMERAL maxSize=20GB +
#                   topolvm-data UserVolumeConfig grow=true) wired
#                   into cluster.yaml on 2026-05-06, but Talos
#                   partitions the disk only at INSTALL time. The
#                   running fleet had EPHEMERAL consume the whole
#                   disk (105GB on a 107GB disk; verified via
#                   talosctl get volumestatuses), leaving zero free
#                   space for topolvm-data → vg-bootstrap
#                   FailedMount → topolvm-lvmd vg-data not found →
#                   infrastructure-storage Kustomization stuck →
#                   entire vault/external-secrets/cloudnative-nats/
#                   lakehouse/notifications/telemetry cascade
#                   blocked. PUT-reinstalls every Contabo VPS so
#                   Talos partitions per the new VolumeConfig from
#                   first boot. Pairs with 02-oracle-infra gen=14
#                   destroy+create in the same apply.
#  20 — 2026-05-07: rename UserVolumeConfig topolvm-data → local-
#                   path-provisioner to align mount path with
#                   Sidero's documented setup
#                   (https://docs.siderolabs.com/kubernetes-guides/
#                    csi/local-storage). Talos auto-mounts user
#                   volumes at /var/mnt/<name>, and renaming creates
#                   a new partition entry — existing nodes already
#                   have the disk fully claimed by the old name, so
#                   the new partition has no free space to land in
#                   without a fresh install. PUT-reinstalls every
#                   Contabo VPS so the disk gets repartitioned with
#                   the new name from first boot. Pairs with
#                   02-oracle-infra gen=15 destroy+create.
#  21 — 2026-05-07: pin Flannel's inter-node interface to KubeSpan
#                   (cluster.network.cni.flannel.extraArgs:
#                    [--iface=kubespan]) so pod MTU drops from
#                   8950 (host eth0 jumbo - 50 vxlan) to 1370
#                   (kubespan WG 1420 - 50 vxlan). Verified the
#                   underlying bug: cross-node TCP/TLS handshake
#                   blackholed because the cert-chain reply
#                   exceeded the WG path MTU and got dropped
#                   without ICMPv6 PTB feedback (vault-openbao
#                   bootstrap pod could ping pod-0 but every TLS
#                   handshake timed out at 5s on the server-hello).
#                   The Flannel CNI manifest is bootstrap-only on
#                   Talos, so applying the new --iface arg requires
#                   a reinstall rather than a config edit. Pairs
#                   with 02-oracle-infra gen=16 destroy+create.
#  22 — 2026-05-24: post 2026-05-23 omni-host flip (Contabo → OCI
#                   bwire) + cluster wipe. First roll's images
#                   carried the new-Omni token but every machine
#                   stuck at `connected: false` after a brief
#                   register (token consumed at join, no persistent
#                   identity established before disconnect).
#                   Re-PUT every Contabo VPS with a freshly-downloaded
#                   image. Pairs with 02-oracle-infra gen=17.
force_reinstall_generation = 22
