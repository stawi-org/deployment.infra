# tofu/layers/03-talos/image.tf
#
# Image factory schematic and installer URL used for upgrade detection
# and machine-configs.yaml metadata. Mirrors the schematic used in
# layer 01 (same shared/schematic.yaml) so the schematic_id is stable
# across layers.

locals {
  _base_schematic = yamldecode(file("${path.module}/../../shared/schematic.yaml"))
  _schematic_with_siderolink = var.omni_siderolink_url == "" ? local._base_schematic : merge(local._base_schematic, {
    customization = merge(local._base_schematic.customization, {
      extraKernelArgs = concat(
        local._base_schematic.customization.extraKernelArgs,
        ["siderolink.api=${var.omni_siderolink_url}"],
      )
    })
  })
}

resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(local._schematic_with_siderolink)
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
  architecture  = "amd64"
}
