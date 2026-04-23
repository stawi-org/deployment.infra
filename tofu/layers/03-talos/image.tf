# tofu/layers/03-talos/image.tf
#
# Image factory schematic and installer URL used for upgrade detection
# and machine-configs.yaml metadata. Mirrors the schematic used in
# layer 01 (same shared/schematic.yaml) so the schematic_id is stable
# across layers.

resource "talos_image_factory_schematic" "this" {
  schematic = file("${path.module}/../../shared/schematic.yaml")
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
  architecture  = "amd64"
}
