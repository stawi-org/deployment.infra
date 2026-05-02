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
#   5 — 2026-05-02: re-bump after reverting the SSH-lockdown attempt
#                   (PR #131 + revert PR #132). The lockdown's cloud-
#                   init shape (no ssh_authorized_keys threaded onto
#                   root + disable_root: true) left the host non-
#                   functional after reinstall — /healthz returned
#                   521 for 25+ min and we had no diagnostic path
#                   in without SSH. Bumping past gen=4 (which is
#                   the broken state in tfstate) rolls the host back
#                   onto the known-working SSH-enabled cloud-init.
force_reinstall_generation = 5

# Native etcd backup → OCI omni-backup-storage. Default false here
# because flipping it true changes the rendered docker-compose YAML
# (adds --etcd-backup-s3 flag), which trips user_data_sha drift in
# null_resource.ensure_image and forces a Contabo PUT reinstall.
# Operator-driven enablement order:
#   1. Mint OCI Customer Secret Key for the omni-backup-writer IAM
#      user in OCI bwire console (User > Customer Secret Keys).
#   2. Add OMNI_ETCD_BACKUP_S3_ACCESS_KEY_ID +
#      OMNI_ETCD_BACKUP_S3_SECRET_ACCESS_KEY as repo Actions secrets;
#      OMNI_ETCD_BACKUP_S3_BUCKET / REGION / ENDPOINT as repo Vars.
#   3. Trigger sync-cluster-template (push to main or
#      workflow_dispatch) so Omni gets the EtcdBackupS3Configs +
#      backupConfiguration.interval.
#   4. Flip this to true here, optionally bump
#      force_reinstall_generation, apply via tofu-omni-host.yml.
# etcd_backup_enabled = true
