# tofu/layers/01-contabo-infra/image.tf
resource "talos_image_factory_schematic" "this" {
  schematic = templatefile("${path.module}/../../shared/schematic.yaml.tftpl", {
    siderolink_url = var.omni_siderolink_url
  })
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
  architecture  = "amd64"
}

# terraform_data that replaces whenever a new reinstall request
# (cluster-wide OR per-node) lands under .github/reconstruction/.
# Replacement chains into contabo_image via lifecycle.replace_triggered_by
# below — that gives every reinstall a fresh imageId, which is required
# because Contabo's PUT /compute/instances/{id} treats imageId-equals-
# current as a metadata no-op (accepts HTTP 200 but does not actually
# re-image the disk). Observed directly: prior attempts with stable
# imageIds left disks on v1.13.0-alpha.2 across three reinstall cycles.
#
# triggers_replace (not input) — input is an updatable attribute and
# does NOT trigger replacement. A prior iteration used input, tofu
# updated in-place, kept the same sentinel id, and the chain never
# fired.
resource "terraform_data" "image_reinstall_marker" {
  triggers_replace = local.any_reinstall_marker
}

resource "contabo_image" "talos" {
  for_each = local.contabo_accounts_effective

  provider = contabo.account[each.key]

  name        = "Talos ${var.talos_version}-${each.key}"
  image_url   = data.talos_image_factory_urls.this.urls.iso
  os_type     = "Linux"
  version     = var.talos_version
  description = "Talos v${var.talos_version} metal-amd64"

  # Explicit replacement on every new reinstall request. Whether
  # contabo_image treats name as ForceNew or updatable, this guarantees
  # a NEW image UUID per request, which is the fact ensure-image.sh
  # relies on to get Contabo to actually re-image the disk.
  lifecycle {
    replace_triggered_by = [terraform_data.image_reinstall_marker]
  }
}
