# tofu/layers/02-oci-storage/image-registry.tf
#
# OCI Object Storage buckets that replace several of the cluster's
# Cloudflare-R2 buckets. All four buckets in the bwire tenancy:
#
# bwire/cluster-image-registry   public  Talos images
# bwire/cluster-state-storage    private tofu state files
# bwire/cluster-vault-storage    private SOPS-encrypted secrets
# bwire/omni-backup-storage      private Omni etcd backups
#
# Single-tenancy bwire layer — no per-account matrix. Compare to
# 02-oracle-infra/ which still runs as a per-account matrix for VCN
# / instances / bastion / Talos custom image (everything except
# buckets + IAM, which moved here).
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

# ---- bwire: cluster-image-registry (public) + cluster-state-storage + cluster-vault-storage --------

data "oci_objectstorage_namespace" "this" {
  provider = oci.bwire
}

resource "oci_objectstorage_bucket" "cluster_image_registry" {
  provider       = oci.bwire
  compartment_id = local.bwire_compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "cluster-image-registry"

  # Anonymous GETs allowed (cross-account image-import + the
  # pkgs.stawi.org CF custom domain don't need OCI credentials),
  # anonymous LISTs denied (still requires authenticated CLI).
  access_type  = "ObjectRead"
  storage_tier = "Standard"
  versioning   = "Disabled"
}

resource "oci_objectstorage_bucket" "cluster_state_storage" {
  provider       = oci.bwire
  compartment_id = local.bwire_compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "cluster-state-storage"

  access_type  = "NoPublicAccess"
  storage_tier = "Standard"
  # Tofu's S3 backend leans on object versioning for rollback after
  # a botched apply, and OCI's S3-compat exposes the same semantics.
  versioning = "Enabled"
}

resource "oci_objectstorage_bucket" "cluster_vault_storage" {
  provider       = oci.bwire
  compartment_id = local.bwire_compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
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
  provider       = oci.bwire
  compartment_id = local.bwire_compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = "omni-backup-storage"

  access_type  = "NoPublicAccess"
  storage_tier = "Standard"
  versioning   = "Disabled"
}
