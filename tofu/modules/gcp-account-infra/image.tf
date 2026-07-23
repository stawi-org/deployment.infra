# tofu/modules/gcp-account-infra/image.tf
#
# Image *bytes* are built once by sync-talos-images (Omni-aware media
# cannot be produced by the google provider). This module only resolves
# which GCE image to boot:
#
#   1. Catalog pin: formats.gcp.accounts.<acct>.self_link (preferred)
#   2. Image family: projects/<project>/global/images/family/stawi-talos
#      (idempotent after the first import lands a family member)
#
# Existing instances ignore boot_disk drift (node-gcp) so catalog
# refreshes never recreate the fleet. New instances always take the
# resolved image at create time.

locals {
  talos_images = fileexists("${var.local_inventory_dir}/talos-images.yaml") ? yamldecode(
    file("${var.local_inventory_dir}/talos-images.yaml")
  ) : {}

  catalog_self_link = try(
    local.talos_images.formats.gcp.accounts[var.account_key].self_link,
    null,
  )

  # Family path is valid GCE image reference syntax. Apply fails clearly
  # if the family has no images yet (run sync-talos-images once).
  family_image = "projects/${var.project_id}/global/images/family/stawi-talos"

  image_self_link = (
    length(local.nodes_effective) == 0
    ? null
    : coalesce(local.catalog_self_link, local.family_image)
  )
}

check "talos_image_resolvable_when_nodes_exist" {
  assert {
    condition = (
      length(local.nodes_effective) == 0
      || local.catalog_self_link != null
      || var.project_id != ""
    )
    error_message = <<-EOT
      account ${var.account_key}: cannot resolve a GCE Talos image.
      Prefer formats.gcp.accounts.${var.account_key}.self_link in
      production/inventory/talos-images.yaml (from sync-talos-images).
      Fallback is image family stawi-talos in project ${var.project_id}.
    EOT
  }
}
