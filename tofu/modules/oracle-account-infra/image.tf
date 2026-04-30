# tofu/modules/oracle-account-infra/image.tf
#
# Per Task 5 of the Omni-takeover (docs/superpowers/plans/2026-04-30-
# omni-takeover.md): OCI image upload + import moves entirely into
# the regenerate-talos-images workflow's per-account matrix. This
# module just looks up the workflow-emitted OCID from the inventory
# and registers shape compat for it.
#
# Removed (the regen workflow now owns these):
#   - talos_image_factory_schematic.this
#   - data.talos_image_factory_urls.this
#   - data.oci_objectstorage_namespace.this
#   - oci_objectstorage_bucket.talos_images
#   - oci_objectstorage_object.talos_qcow2
#   - oci_core_image.talos
#   - terraform_data.image_generation
#
# `removed { lifecycle { destroy = false } }` blocks at the bottom
# drop these resources from tofu state without destroying the
# underlying OCI artifacts (the workflow continues to manage them).
#
# Kept: oci_core_shape_management.talos_compat — adding new shape
# compat is still a tofu-side concern (per-account, per-shape,
# depends on var.nodes which only tofu sees).

locals {
  # Source of truth for image bytes + OCIDs. Populated by the
  # regenerate-talos-images workflow's auto-PR. Per-account OCIDs
  # land under .formats.oracle.accounts.<profile>.ocid.
  talos_images = yamldecode(file("${path.module}/../../shared/inventory/talos-images.yaml"))

  # Per-account OCID lookup. If the account is missing from the
  # inventory's accounts map (e.g. the operator just added it but
  # the regen workflow hasn't republished yet), this errors at plan
  # time with a clear "key 'X' does not exist" — desired loud-fail.
  image_ocid = local.talos_images.formats.oracle.accounts[var.account_key].ocid
}

# OCI imports custom images with an empty compatible-shape list by
# default — even when the .oci archive's metadata declares
# shapeCompatibilities, that's documentation, not registration.
# Instances launched on a shape not in this table fail with:
#   400-InvalidParameter, Shape <X> is not valid for image <...>
# AddImageShapeCompatibilityEntry is idempotent (PUT semantics), so
# reruns are cheap. for_each over the distinct shapes used by
# var.nodes so adding a new shape family later just registers an
# extra entry.
resource "oci_core_shape_management" "talos_compat" {
  for_each       = toset([for n in values(var.nodes) : n.shape])
  compartment_id = var.compartment_ocid
  image_id       = local.image_ocid
  shape_name     = each.key
}

# Drop the old tofu-managed image-build resources from state without
# destroying the OCI artifacts. The regen workflow owns them now —
# bucket, object, and image continue to exist in OCI; tofu just
# stops tracking them. Without `lifecycle { destroy = false }`,
# tofu would attempt to delete the running OCI image and break
# every instance referencing it.
removed {
  from = oci_core_image.talos
  lifecycle { destroy = false }
}

removed {
  from = oci_objectstorage_object.talos_qcow2
  lifecycle { destroy = false }
}

removed {
  from = oci_objectstorage_bucket.talos_images
  lifecycle { destroy = false }
}

removed {
  from = talos_image_factory_schematic.this
  lifecycle { destroy = false }
}

removed {
  from = terraform_data.image_generation
  lifecycle { destroy = false }
}
