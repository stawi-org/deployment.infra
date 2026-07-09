# Substrate hosting omni-host: "contabo" adopts existing VPS 202727781
# (former bwire-3); "oci" provisions an A1.Flex in OCI bwire.
# Note: Always Free A1 is 2 OCPU / 12 GB *total* per tenancy
# (post 2026-06-15). An OCI omni-host at 2/12 leaves zero free A1
# headroom for cluster nodes in the same tenancy.
#
# Reverted to "contabo" 2026-05-24 after OCI eu-frankfurt-1 stopped
# forwarding inbound public traffic to newly-created VMs in the bwire
# tenancy — VM RUNNING + instance-agent healthy internally, but every
# tested public IP (92.5.x ×4 ephemeral, 92.5.69.251 reserved, 89.168.x,
# 138.2.182.31, 158.180.36.132) returned "No route to host" from 18+/20
# global probes (check-host.net DE/NL/FR/PT/ES/SG/UK/SI/JP/US/IL/RU/TR/
# HU/AT/IN/ID nodes). Same break affects the cluster CP nodes in the
# same tenancy, which is why fleet machines kept disconnecting from
# Omni — Talos nodes can't reach the SideroLink WG endpoint on the
# OCI omni-host. Contabo bwire-3's public IP routes globally. OCI CP
# nodes still reach the Contabo omni-host outbound (egress works),
# which is sufficient for SideroLink (nodes initiate the WG tunnel).
omni_host_provider = "contabo"

# Bumped to 4 (2026-05-24) for clean disk wipe + cloud-init re-delivery
# on the Contabo reinstall path. Pairs with the r2_backup_prefix flip
# to a fresh "omni-backups-2026-05-24-contabo" — together they bring
# the Omni stack up on a clean /var/lib/omni with new master keys.
force_reinstall_generation = 4

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
