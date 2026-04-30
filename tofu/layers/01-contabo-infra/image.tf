# tofu/layers/01-contabo-infra/image.tf
#
# Per Task 4 of the Omni-takeover (docs/superpowers/plans/2026-04-30-
# omni-takeover.md): image construction moves out of tofu and into
# the regenerate-talos-images workflow. Tofu just reads the rendered
# inventory and registers the URL with Contabo's image API.
#
# What stayed:
#   - contabo_image per account (Contabo wants its own image UUID
#     for use by contabo_instance.image_id; the URL is the input).
#   - terraform_data.image_reinstall_marker + replace_triggered_by
#     on contabo_image — guarantees a NEW image UUID per reinstall
#     request file. Critical because Contabo's PUT /compute/instances
#     treats imageId-equals-current as a metadata no-op (the disk
#     does NOT get re-imaged). Bug observed in pre-Omni runs.
#   - Per-account image (for_each over contabo_accounts_effective).
#
# What got removed:
#   - talos_image_factory_schematic.this — schematics now ride
#     omnictl through Omni's gRPC, mint happens in CI.
#   - data.talos_image_factory_urls.this — URLs come from
#     tofu/shared/inventory/talos-images.yaml.
#   - var.omni_siderolink_url interpolation — Omni adds SideroLink
#     params at omnictl-download time; we no longer twiddle the
#     schematic per-apply.

locals {
  # Source of truth for image bytes + sha. Populated by the
  # regenerate-talos-images workflow's auto-PR. URL host is a
  # custom-domain-bound R2 bucket (images.stawi.org), so anonymous
  # fetches by Contabo's image API succeed.
  talos_images = yamldecode(file("${path.module}/../../shared/inventory/talos-images.yaml"))
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

  name        = "Talos ${local.talos_images.talos_version}-${each.key}"
  image_url   = local.talos_images.formats.contabo.url
  os_type     = "Linux"
  version     = local.talos_images.talos_version
  description = "Talos ${local.talos_images.talos_version} omni-aware (${local.talos_images.schematic_id})"

  # Explicit replacement on every new reinstall request. Whether
  # contabo_image treats name as ForceNew or updatable, this guarantees
  # a NEW image UUID per request, which is the fact ensure-image.sh
  # relies on to get Contabo to actually re-image the disk.
  lifecycle {
    replace_triggered_by = [terraform_data.image_reinstall_marker]
  }
}
