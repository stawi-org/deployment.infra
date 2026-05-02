# Bump to force a Contabo reinstall of the omni-host VPS via
# null_resource.ensure_image. omni-restore.service pulls the latest
# R2 snapshot on first boot, so the reinstall preserves every cluster
# / Link / MachineLabel — provided omni-backup.timer has fired
# recently (verify before bumping). Pairs with the same knob in
# 01-contabo-infra/02-oracle-infra when rolling the entire fleet.
#
# Bump history:
#   2 — 2026-05-01: land the IPv6-forwarding sysctl drop in
#                   /etc/sysctl.d/99-omni-siderolink-forwarding.conf
#                   on the live host. Cross-CP etcd peering through
#                   the SideroLink hub-and-spoke needs IPv6 forwarding
#                   on the omni-host; without it every cluster
#                   bootstrap loops on `etcd members: deadline
#                   exceeded`. Cloud-init template change rides along
#                   in the same generation bump.
#   3 — 2026-05-01: clean-slate Omni reset. Backup-restore was
#                   reintroducing stale Machine state every cycle
#                   (configured-status mismatched the freshly-
#                   reinstalled Talos nodes' maintenance-mode certs,
#                   so Omni's MaintenanceController never re-handshook;
#                   x509 unknown-authority errors looped indefinitely).
#                   R2 backups deleted manually before this bump so
#                   omni-restore.service finds nothing → fresh Omni,
#                   new CA, new SideroLink join token. Pairs with a
#                   regenerate-talos-images workflow run + cluster
#                   force_reinstall_generation bumps so the fleet
#                   reinstalls onto new-token images and registers
#                   from scratch.
#   4 — 2026-05-02: lock down SSH on the omni-host. Cloud-init no
#                   longer threads ssh_authorized_keys onto the root
#                   user, sshd's PermitRootLogin is now no (was
#                   prohibit-password), and disable_root: true at the
#                   cloud-init level. From this point operators only
#                   reach the host via the WG user-VPN (wg-users) or
#                   the Contabo serial console; everything operational
#                   goes through Omni UI / omnictl / kubectl /
#                   talosctl over the public HTTPS endpoints.
force_reinstall_generation = 4
