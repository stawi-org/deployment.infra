# tofu/layers/01-contabo-infra/image.tf
#
# Reads the Talos image inventory rendered by the
# regenerate-talos-images workflow and registers each account's
# contabo_image with the URL. Contabo issues an image UUID per
# registration; node-contabo's null_resource.ensure_image picks up
# UUID drift via the trigger and PUTs reinstalls.
#
# Image lifecycle is one-directional: when the inventory's URL
# changes (the workflow regenerated images), contabo_image's
# image_url drifts → Contabo issues a new image UUID → instances
# reconcile via the script. No reinstall-request files, no manual
# triggers, no replace_triggered_by chain.

locals {
  talos_images = yamldecode(file("${path.module}/../../shared/inventory/talos-images.yaml"))
}

resource "contabo_image" "talos" {
  for_each = local.contabo_accounts_effective

  provider = contabo.account[each.key]

  name        = "Talos ${local.talos_images.talos_version}-${each.key}"
  image_url   = local.talos_images.formats.contabo.url
  os_type     = "Linux"
  version     = local.talos_images.talos_version
  description = "Talos ${local.talos_images.talos_version} omni-aware (${local.talos_images.schematic_id})"
}
