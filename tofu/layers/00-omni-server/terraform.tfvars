# Substrate hosting omni-host: "contabo" adopts existing VPS 202727781
# (former bwire-3); "oci" provisions an A1.Flex in OCI bwire. Flipped
# to contabo 2026-05-03 — OCI public IPv4 is unstable for cp.stawi.org.
omni_host_provider = "contabo"

# Bumped 2026-05-04 to force a clean disk wipe + cloud-init re-delivery
# on bwire-3. Pairs with the r2_backup_prefix flip to "omni-backups-
# 2026-05-04" in main.tf — together they bring the Omni stack up on a
# fresh /var/lib/omni without state from the broken OCI-era snapshot.
force_reinstall_generation = 2

# bwire_availability_domain_index defaults to 0 (first AD). The
# module auto-discovers ADs via oci_identity_availability_domains
# data source — same pattern oracle-account-infra uses for cluster
# nodes. Bump this only if AD-1 is out of A1.Flex capacity.

# Native etcd backup → OCI omni-backup-storage in bwire. The CSK
# used by Omni's --etcd-backup-s3 flag is now tofu-managed via
# 02-oracle-infra/oci-operator-csk.tf and reaches this layer via
# sync-cluster-template's tfstate read of `omni_backup_writer_credentials`.
# No manual operator CSK mint needed — the bwire tofu-apply creates it.
etcd_backup_enabled = true
