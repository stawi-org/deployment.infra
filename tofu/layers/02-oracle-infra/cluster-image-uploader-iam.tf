# tofu/layers/02-oracle-infra/cluster-image-uploader-iam.tf
#
# Identity for the regenerate-talos-images workflow's writes against
# the cluster-image-registry bucket (alimbacho67, public-read).
# Mirrors the omni-backup-writer pattern from omni-backup-iam.tf
# (gated on local.is_alimbacho67 instead of bwire).
#
# The bucket itself lives in image-registry.tf and serves Talos
# image bytes anonymously over the OCI public URL — but writes still
# need authentication. Rather than handing the workflow the broad
# WIF principal credentials (which would have manage rights across
# the entire alimbacho67 compartment), this carves out a narrow
# IAM user whose policy permits `manage object-family` ONLY on the
# cluster-image-registry bucket.
#
# Credential consumer: regenerate-talos-images.yml's build job
# reads the alimbacho67 tfstate output `cluster_image_uploader_
# credentials` directly via aws s3 cp + jq, exports each field as
# an env var, then runs `aws s3 cp` against OCI's S3-compat
# endpoint to upload the freshly built image objects.
#
# OCI gotchas (same as PR #147):
#   - User + Group MUST live in tenancy_ocid, not compartment_ocid.
#   - Customer Secret Key resource's `id` IS the access-key-id;
#     `key` is the secret.
#   - Policy statements reference groups by NAME; policy itself
#     lives in the bucket's compartment so the target.bucket.name
#     predicate scopes correctly.

resource "oci_identity_group" "cluster_image_uploaders" {
  count          = local.is_alimbacho67 ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].tenancy_ocid
  name           = "cluster-image-uploaders"
  description    = "Identities allowed to write Talos image artifacts to cluster-image-registry."
}

resource "oci_identity_user" "cluster_image_uploader" {
  count          = local.is_alimbacho67 ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].tenancy_ocid
  name           = "cluster-image-uploader"
  description    = "Service identity for the regenerate-talos-images workflow's writes to cluster-image-registry."
  email          = "ops+cluster-image-uploader@stawi.org"
}

resource "oci_identity_user_group_membership" "cluster_image_uploader" {
  count    = local.is_alimbacho67 ? 1 : 0
  provider = oci.account[var.account_key]
  user_id  = oci_identity_user.cluster_image_uploader[0].id
  group_id = oci_identity_group.cluster_image_uploaders[0].id
}

resource "oci_identity_customer_secret_key" "cluster_image_uploader" {
  count        = local.is_alimbacho67 ? 1 : 0
  provider     = oci.account[var.account_key]
  user_id      = oci_identity_user.cluster_image_uploader[0].id
  display_name = "cluster-image-registry-s3"
}

resource "oci_identity_policy" "cluster_image_uploader" {
  count          = local.is_alimbacho67 ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].compartment_ocid
  name           = "cluster-image-uploader-policy"
  description    = "Allow cluster-image-uploaders to manage objects in cluster-image-registry."
  statements = [
    "allow group ${oci_identity_group.cluster_image_uploaders[0].name} to manage object-family in compartment id ${local.oci_accounts_effective[var.account_key].compartment_ocid} where target.bucket.name='${oci_objectstorage_bucket.cluster_image_registry[0].name}'"
  ]
}

output "cluster_image_uploader_credentials" {
  description = "S3-compat credentials for the regenerate-talos-images workflow against cluster-image-registry (alimbacho67 only). Sensitive — contains the Customer Secret Key. Consumed by regenerate-talos-images.yml via direct tfstate read."
  sensitive   = true
  value = local.is_alimbacho67 ? {
    access_key_id     = oci_identity_customer_secret_key.cluster_image_uploader[0].id
    secret_access_key = oci_identity_customer_secret_key.cluster_image_uploader[0].key
    bucket            = oci_objectstorage_bucket.cluster_image_registry[0].name
    region            = local.oci_accounts_effective[var.account_key].region
    endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.alimbacho67[0].namespace,
      local.oci_accounts_effective[var.account_key].region,
    )
    public_url_prefix = format(
      "https://objectstorage.%s.oraclecloud.com/n/%s/b/%s/o",
      local.oci_accounts_effective[var.account_key].region,
      data.oci_objectstorage_namespace.alimbacho67[0].namespace,
      oci_objectstorage_bucket.cluster_image_registry[0].name,
    )
  } : null
}
