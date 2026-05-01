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
force_reinstall_generation = 2
