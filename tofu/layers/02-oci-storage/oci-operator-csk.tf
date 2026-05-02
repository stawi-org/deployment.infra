# tofu/layers/02-oci-storage/oci-operator-csk.tf
#
# Customer Secret Key minted against the existing operator user in
# the bwire OCI tenancy. Single CSK shared by all OCI S3-compat
# consumers:
#   - omni-host's --etcd-backup-s3 flag (writes to omni-backup-storage)
#   - regenerate-talos-images workflow (writes Talos images to
#     cluster-image-registry)
#   - sync-cluster-template's EtcdBackupS3Configs render
#
# Replaces the per-service users (omni-backup-writer,
# cluster-image-uploader) that were retired in PR #156. Trade-off
# documented in the spec at
# docs/superpowers/specs/2026-05-02-oci-storage-extraction-design.md.
#
# OCI permits up to 3 CSKs per user; this resource creates a NEW CSK
# alongside any pre-existing ones. After apply the access-key /
# secret are in tfstate (sensitive). Downstream consumers read via
# the same `aws s3 cp + jq` pattern sync-cluster-template.yml uses
# today.

data "oci_identity_users" "bwire_operator" {
  provider       = oci.bwire
  compartment_id = local.bwire_tenancy_ocid
  name           = var.oci_operator_user_name
}

resource "oci_identity_customer_secret_key" "bwire_operator" {
  provider     = oci.bwire
  user_id      = data.oci_identity_users.bwire_operator.users[0].id
  display_name = "stawi-cluster-s3-compat"
}
