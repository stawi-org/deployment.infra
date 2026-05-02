# tofu/layers/02-oracle-infra/image-registry.tf
#
# Single OCI Object Storage bucket in the alimbacho67 tenancy that
# holds the schematic-keyed Talos image staging area. Replaces the
# previous setup where:
#
#   - the central staging lived in Cloudflare R2 (bucket
#     `cluster-image-registry`) and `pkgs.stawi.org` was a CF custom-
#     domain wrapper around R2;
#   - the regenerate-talos-images workflow then re-uploaded the .oci
#     archive into a per-account `talos-images-<account>` bucket on
#     each OCI tenancy before calling `oci compute image import
#     from-object`.
#
# Why move:
#   - Cross-tenancy reuse: a public-read OCI bucket lets every other
#     account's `image import from-object` (or `image import from-uri`)
#     pull from one canonical place instead of a per-account replica.
#   - One copy → one schematic_id+sha256 fingerprint, no drift between
#     "the bytes the workflow staged in R2" and "the bytes that
#     actually got imported into account X's bucket".
#   - Egress cost: OCI internal transfer is free; OCI-to-OCI fetches
#     don't traverse R2 at all.
#   - `pkgs.stawi.org` (operator-facing CF custom domain) flips from
#     R2 to a CF worker that proxies to the OCI bucket — same URL
#     shape, same cache behavior, different origin.
#
# Why alimbacho67 specifically: it already hosts the cluster control-
# plane post-phase-1 reshape, so it's the "hub" account in our mental
# model. Always-Free compartment quota (200 GB Object Storage) covers
# the ~4 GB image inventory comfortably.
#
# Public access: ObjectRead = anonymous GETs work, anonymous LISTs do
# NOT (operators can still LIST via authenticated OCI CLI). The only
# 'secret' inside a Talos image is the SideroLink shared join token
# embedded in the kernel cmdline; that token is intentionally
# rotatable from the Omni side and isn't a long-term secret. If you
# want a defense-in-depth layer, swap to NoPublicAccess + per-import
# Pre-Authenticated-Request URLs in a follow-up.

data "oci_objectstorage_namespace" "alimbacho67" {
  provider       = oci.account["alimbacho67"]
  compartment_id = local.oci_accounts_effective["alimbacho67"].compartment_ocid
}

resource "oci_objectstorage_bucket" "cluster_image_registry" {
  provider       = oci.account["alimbacho67"]
  compartment_id = local.oci_accounts_effective["alimbacho67"].compartment_ocid
  namespace      = data.oci_objectstorage_namespace.alimbacho67.namespace
  name           = "cluster-image-registry"

  # Anonymous GETs allowed (LE/cross-account image-import doesn't need
  # OCI credentials), anonymous LISTs denied (still need creds to
  # enumerate). Authenticated callers retain full access.
  access_type = "ObjectRead"

  # Standard tier is enough — these are write-once-read-many image
  # blobs, no need for the Archive tier's restore-latency tradeoff.
  storage_tier = "Standard"

  # Object-level versioning off: regen output objects already carry
  # a sha-suffixed name (e.g. metal-amd64-omni-stawi-v1.13.0-d79740.iso),
  # so identical bytes always overwrite their own object idempotently
  # and content changes show up as new object names. Versioning would
  # bloat storage with no operational gain.
  versioning = "Disabled"
}

output "cluster_image_registry" {
  description = "Public OCI Object Storage bucket holding the schematic-keyed Talos image staging area. URL form: https://objectstorage.<region>.oraclecloud.com/n/<namespace>/b/<bucket>/o/<object>."
  value = {
    namespace = data.oci_objectstorage_namespace.alimbacho67.namespace
    bucket    = oci_objectstorage_bucket.cluster_image_registry.name
    region    = local.oci_accounts_effective["alimbacho67"].region
    public_url_prefix = format(
      "https://objectstorage.%s.oraclecloud.com/n/%s/b/%s/o",
      local.oci_accounts_effective["alimbacho67"].region,
      data.oci_objectstorage_namespace.alimbacho67.namespace,
      oci_objectstorage_bucket.cluster_image_registry.name,
    )
  }
}
