# tofu/layers/02-oracle-infra/image-registry.tf
#
# OCI Object Storage buckets that replace several of the cluster's
# Cloudflare-R2 buckets. All four buckets in the bwire tenancy:
#
#   bwire   cluster-image-registry   public  Talos images
#   bwire   cluster-state-storage    private tofu state files
#   bwire   cluster-vault-storage    private SOPS-encrypted secrets
#   bwire   omni-backup-storage      private Omni etcd backups
#
# Layer 02-oracle-infra runs as a per-account MATRIX (each account
# has its own tfstate, its own oci provider alias). Resources here
# need to gate on `var.account_key` so each account's apply only
# creates its own buckets — referencing oci.account["other"] from
# inside account X's run fails with "Provider instance not present".
#
# `oci.account[var.account_key]` is the only provider available in
# any given run, so use it (not a hard-coded alias) and rely on the
# `count = var.account_key == "..." ? 1 : 0` gate to keep
# resources scoped to the right tenancy's apply.
#
# Why move off R2:
#   - Colocation: OCI image-import / OCI-resident bwire compute pulls
#     from local Object Storage instead of crossing cloud boundaries.
#   - Single source of truth: no drift between "the bytes R2 has" and
#     "the bytes account X imported / restored".
#   - Free-tier headroom: Object Storage has a 200 GB Always-Free
#     quota per tenancy. Image inventory is ~4 GB; tofu state +
#     vault are sub-MB.
#
# `pkgs.stawi.org` (operator-facing CF custom domain that today wraps
# R2) flips to a CF Worker that proxies to bwire's
# cluster-image-registry public URL — same URL shape, different
# origin. Migration of existing R2 contents and the worker live in
# follow-up PRs.

locals {
  # Per-account gates — exactly one of these is true in any given
  # matrix-run. Lets the resources below stay tenancy-scoped without
  # duplicating per-tenancy module wrappers.
  is_alimbacho67 = var.account_key == "alimbacho67"
  is_bwire       = var.account_key == "bwire"
}

# ---- bwire: cluster-image-registry (public) + cluster-state-storage + cluster-vault-storage --------

data "oci_objectstorage_namespace" "bwire" {
  count    = local.is_bwire ? 1 : 0
  provider = oci.account[var.account_key]
}

resource "oci_objectstorage_bucket" "cluster_image_registry" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].compartment_ocid
  namespace      = data.oci_objectstorage_namespace.bwire[0].namespace
  name           = "cluster-image-registry"

  # Anonymous GETs allowed (cross-account image-import + the
  # pkgs.stawi.org CF custom domain don't need OCI credentials),
  # anonymous LISTs denied (still requires authenticated CLI).
  access_type  = "ObjectRead"
  storage_tier = "Standard"
  versioning   = "Disabled"
}

resource "oci_objectstorage_bucket" "cluster_state_storage" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].compartment_ocid
  namespace      = data.oci_objectstorage_namespace.bwire[0].namespace
  name           = "cluster-state-storage"

  access_type  = "NoPublicAccess"
  storage_tier = "Standard"
  # Tofu's S3 backend leans on object versioning for rollback after
  # a botched apply, and OCI's S3-compat exposes the same semantics.
  versioning = "Enabled"
}

resource "oci_objectstorage_bucket" "cluster_vault_storage" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].compartment_ocid
  namespace      = data.oci_objectstorage_namespace.bwire[0].namespace
  name           = "cluster-vault-storage"

  access_type  = "NoPublicAccess"
  storage_tier = "Standard"
  versioning   = "Enabled"
}

# ---- bwire: omni-backup-storage (private) ------------------------
#
# Backing store for Omni's builtin etcd backup feature
# (--etcd-backup-s3 server flag + cluster.backupConfiguration in the
# cluster template). Lives in bwire because that's where the omni-
# host itself lands in Phase 2 — colocation keeps backup writes
# off-network.
#
# Replaces the custom /var/lib/omni tarball flow targeted at R2:
# Omni's native cluster-etcd backup is point-in-time consistent
# (etcd snapshot via raft) and incremental, where our tarball
# requires stopping the omni-stack to get a consistent /var/lib/omni
# read. Native is strictly better for cluster-state recovery.
#
# We still keep the host-level tarball for things Omni doesn't
# back up (master keys at /var/lib/omni/keys, sqlite audit log at
# /var/lib/omni/omni.db, /etc/wireguard, /etc/letsencrypt). That
# tarball can stay in cluster-state-storage (or move to
# omni-backup-storage with a different prefix) — operator's call.
#
# Versioning OFF for omni-backup-storage: Omni stamps each backup
# object with a monotonic timestamp suffix so rollbacks don't need
# version IDs, and turning versioning on doubles storage for no
# operational gain.

resource "oci_objectstorage_bucket" "omni_backup_storage" {
  count          = local.is_bwire ? 1 : 0
  provider       = oci.account[var.account_key]
  compartment_id = local.oci_accounts_effective[var.account_key].compartment_ocid
  namespace      = data.oci_objectstorage_namespace.bwire[0].namespace
  name           = "omni-backup-storage"

  access_type  = "NoPublicAccess"
  storage_tier = "Standard"
  versioning   = "Disabled"
}

output "cluster_image_registry" {
  description = "Public OCI Object Storage bucket holding the schematic-keyed Talos image staging area (bwire only)."
  value = local.is_bwire ? {
    namespace = data.oci_objectstorage_namespace.bwire[0].namespace
    bucket    = oci_objectstorage_bucket.cluster_image_registry[0].name
    region    = local.oci_accounts_effective[var.account_key].region
    public_url_prefix = format(
      "https://objectstorage.%s.oraclecloud.com/n/%s/b/%s/o",
      local.oci_accounts_effective[var.account_key].region,
      data.oci_objectstorage_namespace.bwire[0].namespace,
      oci_objectstorage_bucket.cluster_image_registry[0].name,
    )
  } : null
}

output "cluster_state_storage" {
  description = "Private OCI Object Storage bucket holding tofu state files (bwire only). Use the S3-compat endpoint with a Customer Secret Key."
  value = local.is_bwire ? {
    namespace = data.oci_objectstorage_namespace.bwire[0].namespace
    bucket    = oci_objectstorage_bucket.cluster_state_storage[0].name
    region    = local.oci_accounts_effective[var.account_key].region
    s3_endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.bwire[0].namespace,
      local.oci_accounts_effective[var.account_key].region,
    )
  } : null
}

output "cluster_vault_storage" {
  description = "Private OCI Object Storage bucket holding SOPS-encrypted secrets (bwire only). Use the S3-compat endpoint."
  value = local.is_bwire ? {
    namespace = data.oci_objectstorage_namespace.bwire[0].namespace
    bucket    = oci_objectstorage_bucket.cluster_vault_storage[0].name
    region    = local.oci_accounts_effective[var.account_key].region
    s3_endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.bwire[0].namespace,
      local.oci_accounts_effective[var.account_key].region,
    )
  } : null
}

output "omni_backup_storage" {
  description = "Private OCI Object Storage bucket for Omni's builtin etcd backup feature (bwire only). Wire to omni-server via --etcd-backup-s3 + S3 env vars in the omni docker-compose."
  value = local.is_bwire ? {
    namespace = data.oci_objectstorage_namespace.bwire[0].namespace
    bucket    = oci_objectstorage_bucket.omni_backup_storage[0].name
    region    = local.oci_accounts_effective[var.account_key].region
    s3_endpoint = format(
      "https://%s.compat.objectstorage.%s.oraclecloud.com",
      data.oci_objectstorage_namespace.bwire[0].namespace,
      local.oci_accounts_effective[var.account_key].region,
    )
  } : null
}
