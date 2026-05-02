# OCI availability-domain in the bwire tenancy/region. Operator must
# set this to an AD with A1.Flex capacity. Look up via:
#   oci iam availability-domain list --profile bwire
bwire_availability_domain = "<set-by-operator>"

# Native etcd backup → OCI omni-backup-storage in bwire. The CSK
# used by Omni's --etcd-backup-s3 flag is now tofu-managed via
# 02-oracle-infra/oci-operator-csk.tf and reaches this layer via
# sync-cluster-template's tfstate read of `omni_backup_writer_credentials`.
# No manual operator CSK mint needed — the bwire tofu-apply creates it.
etcd_backup_enabled = true
