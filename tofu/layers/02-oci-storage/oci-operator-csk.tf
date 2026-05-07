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

# Looking up the operator user by exact name fails when OCI stores
# the user under a federated/IDCS namespace prefix (typical patterns:
#   oracleidentitycloudservice/<email>
#   <idp_name>/<email>
# ). Listing ALL users in the tenancy and matching by suffix-or-exact
# is more robust across federation shapes. The match runs over the
# raw provider response and surfaces the matched OCID via a local;
# if no match, validation triggers a clear error.
data "oci_identity_users" "all" {
  provider       = oci.bwire
  compartment_id = local.bwire_tenancy_ocid
}

locals {
  # Try exact match first; if not, search for a name ending in
  # "/${var.oci_operator_user_name}" (federated prefix form).
  bwire_operator_users = [
    for u in data.oci_identity_users.all.users :
    u
    if u.name == var.oci_operator_user_name
    || endswith(u.name, "/${var.oci_operator_user_name}")
  ]
}

check "bwire_operator_user_found" {
  assert {
    condition = length(local.bwire_operator_users) > 0
    error_message = format(
      "No user matching '%s' (or '<idp>/%s') in bwire tenancy. Available users: %s",
      var.oci_operator_user_name,
      var.oci_operator_user_name,
      jsonencode([for u in data.oci_identity_users.all.users : u.name]),
    )
  }
}

resource "oci_identity_customer_secret_key" "bwire_operator" {
  provider     = oci.bwire
  user_id      = local.bwire_operator_users[0].id
  display_name = "stawi-cluster-s3-compat"
}
