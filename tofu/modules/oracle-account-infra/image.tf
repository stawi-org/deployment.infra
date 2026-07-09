# tofu/modules/oracle-account-infra/image.tf
#
# Per Task 5 of the Omni-takeover (docs/superpowers/plans/2026-04-30-
# omni-takeover.md): OCI image upload + import moves entirely into
# the sync-talos-images workflow's per-account matrix. This
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
  # sync-talos-images workflow, which writes directly to R2 at
  # production/inventory/talos-images.yaml. The consuming layer
  # syncs that R2 prefix locally pre-plan via `aws s3 sync`, so the
  # file lives at ${var.local_inventory_dir}/talos-images.yaml.
  # Per-account OCIDs land under .formats.oracle.accounts.<profile>.ocid.
  talos_images = yamldecode(file("${var.local_inventory_dir}/talos-images.yaml"))

  # Per-account OCID lookup. Empty-node accounts (declared in
  # accounts.yaml but not yet carrying VMs) skip the lookup so plan
  # succeeds without a talos-images.yaml entry. Missing OCID with
  # non-empty nodes still fails loud at plan time.
  image_ocid = (
    length(var.nodes) == 0
    ? null
    : try(local.talos_images.formats.oracle.accounts[var.account_key].ocid, null)
  )
}

check "talos_image_ocid_present_when_nodes_exist" {
  assert {
    condition     = length(var.nodes) == 0 || local.image_ocid != null
    error_message = <<-EOT
      account ${var.account_key}: nodes are declared but no custom-image OCID in
      production/inventory/talos-images.yaml (formats.oracle.accounts.${var.account_key}.ocid).
      Run sync-talos-images / cluster-provision mode=images for this tenancy first.
    EOT
  }
}

# OCI imports custom images with an empty compatible-shape list by
# default — even when the .oci archive's metadata declares
# shapeCompatibilities, that's documentation, not registration.
# Instances launched on a shape not in this table fail with:
#   400-InvalidParameter, Shape <X> is not valid for image <...>
# AddImageShapeCompatibilityEntry is idempotent (PUT semantics), so
# reruns are cheap. for_each over the distinct shapes used by
# var.nodes so adding a new shape family later just registers an
# extra entry. Empty when image_ocid is null (no nodes).
resource "oci_core_shape_management" "talos_compat" {
  for_each       = local.image_ocid == null ? toset([]) : toset([for n in values(var.nodes) : n.shape])
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
