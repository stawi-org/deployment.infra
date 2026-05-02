# tofu/layers/02-oracle-infra/omni-backup-iam.tf
#
# Identity for Omni's --etcd-backup-s3 destination. The
# omni-backup-storage bucket lives in this layer (image-registry.tf,
# bwire only), so the matching IAM user + group + policy + customer
# secret key live here too — keeps the bucket and credential
# lifecycles in lock-step.
#
# Credential consumer: sync-cluster-template.yml reads the tfstate
# output `omni_backup_writer_credentials` and renders
# tofu/shared/clusters/etcd-backup-s3-configs.yaml.tmpl with the
# values inlined, then `omnictl apply -f -` installs the
# EtcdBackupS3Configs resource on the running Omni instance. No
# operator copy-and-paste required.
#
# OCI gotchas baked in:
#   1. Identity resources (User, Group) MUST live in the tenancy
#      OCID, not a child compartment. Using compartment_ocid here
#      fails with "compartment ... does not allow Users".
#   2. The Customer Secret Key resource's `id` IS the access-key-id
#      for S3-compat (formatted as OCID); `key` is the secret. Don't
#      confuse with AWS IAM where access keys have their own ID
#      separate from the user.
#   3. Policy statements reference groups by NAME, not OCID, and
#      the policy itself lives in the bucket's compartment so its
#      target.bucket.name predicate scopes correctly.
#   4. Customer Secret Key creation is one-shot: the secret is
#      returned only at create time. To rotate, taint the resource
#      so tofu destroys and recreates — the new secret flows back
#      through tfstate output → sync-cluster-template's render.

resource "oci_identity_group" "omni_backup_writers" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].tenancy_ocid
  name           = "omni-backup-writers"
  description    = "Identities allowed to write Omni etcd backups to omni-backup-storage."
}

resource "oci_identity_user" "omni_backup_writer" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].tenancy_ocid
  name           = "omni-backup-writer"
  description    = "Service identity for Omni's --etcd-backup-s3 destination (writes to omni-backup-storage)."
  email          = "ops+omni-backup-writer@stawi.org"
}

resource "oci_identity_user_group_membership" "omni_backup_writer" {
  count    = local.is_bwire ? 1 : 0
  provider = oci.account[var.account_key]
  user_id  = oci_identity_user.omni_backup_writer[0].id
  group_id = oci_identity_group.omni_backup_writers[0].id
}

resource "oci_identity_customer_secret_key" "omni_backup_writer" {
  count        = local.is_bwire ? 1 : 0
  provider     = oci.account[var.account_key]
  user_id      = oci_identity_user.omni_backup_writer[0].id
  display_name = "omni-etcd-backup-s3"
}

resource "oci_identity_policy" "omni_backup_writer" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].compartment_ocid
  name           = "omni-backup-writer-policy"
  description    = "Allow omni-backup-writers to manage objects in omni-backup-storage."
  statements = [
    "allow group ${oci_identity_group.omni_backup_writers[0].name} to manage object-family in compartment id ${local.oci_accounts_effective[var.account_key].compartment_ocid} where target.bucket.name='${oci_objectstorage_bucket.omni_backup_storage[0].name}'"
  ]
}

output "omni_backup_writer_credentials" {
  description = "S3-compat credentials for Omni's --etcd-backup-s3 against omni-backup-storage (bwire only). Sensitive — contains the Customer Secret Key. Consumed by sync-cluster-template.yml via direct tfstate read."
  sensitive   = true
  value = local.is_bwire ? {
    access_key_id     = oci_identity_customer_secret_key.omni_backup_writer[0].id
    secret_access_key = oci_identity_customer_secret_key.omni_backup_writer[0].key
    bucket            = oci_objectstorage_bucket.omni_backup_storage[0].name
    region            = local.oci_accounts_effective[var.account_key].region
    endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.bwire[0].namespace,
      local.oci_accounts_effective[var.account_key].region,
    )
  } : null
}
