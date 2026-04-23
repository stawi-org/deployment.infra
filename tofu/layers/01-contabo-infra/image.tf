# tofu/layers/01-contabo-infra/image.tf
resource "talos_image_factory_schematic" "this" {
  schematic = file("${path.module}/../../shared/schematic.yaml")
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "metal"
  architecture  = "amd64"
}

# Image name includes var.force_reinstall_generation so bumping the
# generation produces a brand-new Contabo custom image with a brand-new
# UUID. That guarantees null_resource.ensure_image's PUT payload has a
# target imageId that's DIFFERENT from whatever the instance currently
# reports in its metadata — without that difference Contabo treats the
# PUT as a no-op (accepts HTTP 200, doesn't re-image the disk).
# Observed directly: previous attempts had PUT target == live imageId,
# and the disk stayed on v1.13.0-alpha.2 across three reinstall cycles.
# terraform_data that replaces on force_reinstall_generation change.
# MUST use triggers_replace (not input) — input is an updatable
# attribute and does NOT trigger replacement. Previous iteration used
# `input` and tofu updated the resource in-place, kept the same
# sentinel id, and lifecycle.replace_triggered_by on contabo_image
# never fired → Contabo image UUID stayed the same across generations
# → reinstall PUT was still a metadata no-op.
resource "terraform_data" "image_generation" {
  triggers_replace = var.force_reinstall_generation
}

resource "contabo_image" "talos" {
  name = "Talos ${var.talos_version} gen${var.force_reinstall_generation}"
  # The urls.iso attribute is the installer ISO URL for the metal platform.
  # If the Talos provider schema uses a different attribute name (e.g. urls.installer),
  # update this reference — Phase 4 validation will surface it.
  image_url   = data.talos_image_factory_urls.this.urls.iso
  os_type     = "Linux"
  version     = var.talos_version
  description = "Talos v${var.talos_version} metal-amd64 (gen ${var.force_reinstall_generation})"

  # Explicit replacement whenever force_reinstall_generation bumps —
  # whether contabo_image treats name as ForceNew or updatable, this
  # guarantees a NEW image UUID, which is the fact ensure-image.sh
  # relies on to get Contabo to actually re-image the disk.
  lifecycle {
    replace_triggered_by = [terraform_data.image_generation]
  }
}
