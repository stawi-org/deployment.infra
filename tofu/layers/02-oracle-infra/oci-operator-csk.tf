# tofu/layers/02-oracle-infra/oci-operator-csk.tf
#
# bwire-only Customer Secret Key, minted against the existing
# operator user (looked up by name via data.oci_identity_users).
# Single CSK shared by all OCI S3-compat consumers:
#   - omni-host's --etcd-backup-s3 flag (writes to omni-backup-storage)
#   - regenerate-talos-images workflow (writes Talos images to
#     cluster-image-registry)
#   - sync-cluster-template's EtcdBackupS3Configs render
#
# Replaces the per-service users (omni-backup-writer,
# cluster-image-uploader). Trade-off documented in the spec at
# docs/superpowers/specs/2026-05-02-omni-oci-realignment-design.md.
#
# OCI permits up to 2 CSKs per user; this resource creates a NEW
# CSK alongside any pre-existing ones. After apply the access-key /
# secret are in tfstate (sensitive). Downstream consumers read via
# the same `aws s3 cp + jq` pattern sync-cluster-template.yml uses
# today.

variable "oci_operator_user_name" {
  type        = string
  description = "Name of the existing OCI operator user in the bwire tenancy. CSK minted against this user. Empty when not bwire."
  default     = ""
  validation {
    # Fail loudly on the bwire cell if the operator forgot to set this.
    # Other accounts (alimbacho67/brianelvis33/ambetera) don't mint a
    # CSK so an empty value is fine; we'd ideally key the validation
    # on local.is_bwire but tofu validation conditions can't read
    # locals — gate via account_key directly.
    condition     = var.account_key != "bwire" || var.oci_operator_user_name != ""
    error_message = "oci_operator_user_name must be set for the bwire cell (the existing operator user that owns the shared S3-compat CSK)."
  }
}

data "oci_identity_users" "bwire_operator" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].tenancy_ocid
  name           = var.oci_operator_user_name
}

resource "oci_identity_customer_secret_key" "bwire_operator" {
  count        = local.is_bwire ? 1 : 0
  provider     = oci.account[var.account_key]
  user_id      = data.oci_identity_users.bwire_operator[0].users[0].id
  display_name = "stawi-cluster-s3-compat"
}

# Output preserves the field shape that sync-cluster-template.yml
# already reads (omni_backup_writer_credentials). Both writes to
# `cluster-image-registry` and `omni-backup-storage` auth via the
# same CSK.
output "omni_backup_writer_credentials" {
  description = "S3-compat credentials (single CSK) for OCI bwire object storage. Used by omni-host etcd-backup, regenerate-talos-images uploads, and sync-cluster-template's EtcdBackupS3Configs render."
  sensitive   = true
  value = local.is_bwire ? {
    access_key_id     = oci_identity_customer_secret_key.bwire_operator[0].id
    secret_access_key = oci_identity_customer_secret_key.bwire_operator[0].key
    bucket            = oci_objectstorage_bucket.omni_backup_storage[0].name
    region            = local.oci_accounts_effective[var.account_key].region
    endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.bwire[0].namespace,
      local.oci_accounts_effective[var.account_key].region,
    )
  } : null
}
