# Substrate hosting omni-host: "contabo" adopts existing VPS 202727781
# (former bwire-3); "oci" provisions an A1.Flex (2 OCPU / 12 GB) in
# OCI bwire. Flipped to "oci" 2026-05-23 as part of the fresh-start
# topology change — Omni now shares the bwire tenancy with one cluster
# CP (oci-bwire-node-1), filling the full Always-Free 4-OCPU / 24-GB cap.
omni_host_provider = "oci"

# Bumped 2026-05-23 to force a clean disk wipe + cloud-init re-delivery.
# Pairs with the r2_backup_prefix flip to "omni-backups-2026-05-23-oci"
# in main.tf — together they bring the Omni stack up on a fresh
# /var/lib/omni without state from the older Contabo-substrate snapshot.
force_reinstall_generation = 3

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
