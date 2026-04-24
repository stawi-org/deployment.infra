# tofu/modules/oracle-account-infra/image.tf
#
# Reuse-or-create for the OCI custom Talos image. The image is identified
# by display_name = "Talos <version> arm64 gen<gen>". On every apply we
# look it up; if it already exists, we use it. If not, we create it from
# either var.talos_image_source_uri (operator-supplied public URL — e.g.
# a pre-uploaded QCOW2 in OCI Object Storage with a PAR or public bucket
# policy) or, falling back, the live talos.factory.dev URL for the
# pinned schematic.
#
# Bumping var.force_image_generation forces a new image (next apply
# creates instead of reusing).

resource "terraform_data" "image_generation" {
  triggers_replace = var.force_image_generation
}

resource "talos_image_factory_schematic" "this" {
  schematic = file("${var.shared_patches_dir}/../schematic.yaml")
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "oracle"
  architecture  = "arm64"
}

locals {
  image_display_name = "Talos ${var.talos_version} arm64 gen${var.force_image_generation}"

  # Operator-supplied public URL takes precedence; falls back to the live
  # Talos image-factory URL. Allows hosting a single QCOW2 in a public OCI
  # Object Storage bucket and reusing it across resets/regions.
  image_source_uri = (
    var.talos_image_source_uri != null && var.talos_image_source_uri != ""
    ? var.talos_image_source_uri
    : data.talos_image_factory_urls.this.urls.disk_image
  )
}

# Probe: list AVAILABLE images in the compartment matching the
# display_name. Excludes deleted images so a previous force-replace
# doesn't shadow the freshly-created one.
data "oci_core_images" "existing" {
  compartment_id = var.compartment_ocid
  display_name   = local.image_display_name
  state          = "AVAILABLE"
}

# Create only when no AVAILABLE image with this display_name exists. After
# the first apply this resource is count = 0 and tofu does not touch OCI.
resource "oci_core_image" "talos" {
  count          = length(data.oci_core_images.existing.images) == 0 ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = local.image_display_name
  launch_mode    = "PARAVIRTUALIZED"
  image_source_details {
    source_type       = "objectStorageUri"
    source_uri        = local.image_source_uri
    source_image_type = "QCOW2"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.image_generation]
  }
}

# Single source-of-truth OCID consumed by nodes.tf. Whether reused or
# freshly created, callers don't care.
locals {
  image_ocid = (
    length(data.oci_core_images.existing.images) > 0
    ? data.oci_core_images.existing.images[0].id
    : oci_core_image.talos[0].id
  )
}
