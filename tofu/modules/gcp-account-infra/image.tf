# tofu/modules/gcp-account-infra/image.tf
#
# Image bytes + GCE self_links are owned by sync-talos-images /
# cluster-provision mode=images. This module only looks up the
# workflow-emitted self_link from inventory (same shape as
# oracle-account-infra's OCID lookup).

locals {
  talos_images = fileexists("${var.local_inventory_dir}/talos-images.yaml") ? yamldecode(
    file("${var.local_inventory_dir}/talos-images.yaml")
  ) : {}
  image_self_link = try(
    local.talos_images.formats.gcp.accounts[var.account_key].self_link,
    null,
  )
}

check "talos_image_present_when_nodes_exist" {
  assert {
    condition     = length(var.nodes) == 0 || local.image_self_link != null
    error_message = <<-EOT
      account ${var.account_key}: nodes declared but no GCE image self_link in
      production/inventory/talos-images.yaml (formats.gcp.accounts.${var.account_key}.self_link).
      Run sync-talos-images / cluster-provision mode=images for this project first.
    EOT
  }
}
