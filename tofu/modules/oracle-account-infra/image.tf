# tofu/modules/oracle-account-infra/image.tf
#
# Custom Talos image creation on OCI, driven by scripts/oci-image-
# create-or-find.sh via a tofu `external` data source.
#
# Why not the native oci_core_image resource: its launch_options field
# is Computed-only in provider 8.11.0. The Talos factory arm64 qcow2
# ships without image_metadata.json, so OCI's auto-detection lands
# wrong defaults (bootVolumeType=ISCSI, no /dev/sda visible to Talos)
# and UpdateImage doesn't accept launch_options post-create. The only
# place we can set the full Talos-prescribed launch_options block at
# CreateImage time is the OCI CLI's --launch-mode CUSTOM + --launch-
# options — hence the external script.
#
# Source URI precedence:
#   1. var.talos_image_source_uri — operator-pinned URL.
#   2. Staged upload from var.talos_qcow2_local_path — workflow-
#      downloaded qcow2 uploaded to a per-account public-read bucket.
#   3. Live factory URL — last-ditch fallback; OCI 400s on external
#      HTTPS but leaves local dev able to at least plan.
#
# Bumping var.force_image_generation changes the image display_name,
# so the next apply creates instead of reusing.

resource "talos_image_factory_schematic" "this" {
  schematic = file("${var.shared_patches_dir}/../schematic.yaml")
}

data "talos_image_factory_urls" "this" {
  talos_version = var.talos_version
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "oracle"
  architecture  = "arm64"
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  image_display_name = "Talos ${var.talos_version} arm64 gen${var.force_image_generation}"

  # Only stage (create bucket + upload) when the workflow pre-downloaded
  # the qcow2 AND no operator-supplied URL pre-empts it.
  stage_local_upload = (
    (var.talos_image_source_uri == null || var.talos_image_source_uri == "")
    && var.talos_qcow2_local_path != null
    && var.talos_qcow2_local_path != ""
  )

  image_bucket_name = "talos-images-${var.account_key}"
  image_object_name = "talos-${var.talos_version}-${talos_image_factory_schematic.this.id}-oracle-arm64.qcow2"

  staged_image_uri = local.stage_local_upload ? format(
    "https://objectstorage.%s.oraclecloud.com/n/%s/b/%s/o/%s",
    var.region,
    data.oci_objectstorage_namespace.this.namespace,
    local.image_bucket_name,
    local.image_object_name,
  ) : ""

  image_source_uri = (
    var.talos_image_source_uri != null && var.talos_image_source_uri != ""
    ? var.talos_image_source_uri
    : (
      local.stage_local_upload
      ? local.staged_image_uri
      : data.talos_image_factory_urls.this.urls.disk_image
    )
  )

  # First shape in var.nodes — every node in one OCI account uses the
  # same shape family (A1.Flex), so registering compat for the first is
  # sufficient. The script PUTs idempotently, so reruns are cheap.
  image_primary_shape = values(var.nodes)[0].shape
}

resource "oci_objectstorage_bucket" "talos_images" {
  count          = local.stage_local_upload ? 1 : 0
  compartment_id = var.compartment_ocid
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = local.image_bucket_name
  # ObjectRead = anonymous ObjectGet (list disabled) — exactly what OCI
  # CreateImage needs when reading sourceUri.
  access_type = "ObjectRead"
}

resource "oci_objectstorage_object" "talos_qcow2" {
  count        = local.stage_local_upload ? 1 : 0
  bucket       = oci_objectstorage_bucket.talos_images[0].name
  namespace    = data.oci_objectstorage_namespace.this.namespace
  object       = local.image_object_name
  source       = var.talos_qcow2_local_path
  content_type = "application/octet-stream"

  # OCI provider stores "source" in state as "<path> <mtime>" so every
  # fresh workflow run (new ephemeral runner, re-downloaded file with a
  # fresh mtime) sees a diff and forces a re-upload of ~100 MB plus a
  # cascaded re-create of the image. The content is pinned by the
  # object name (<version>-<schematic_id>-oracle-arm64.qcow2) so a
  # genuine content change lands as a different object — name-level
  # replacement, not source-level. Ignore source drift after create.
  lifecycle {
    ignore_changes = [source]
  }
}

# Find-or-create the OCI custom image with the exact launch_options
# Talos arm64 needs. The script is idempotent on display_name: if an
# AVAILABLE image with the same display_name exists, it returns its
# OCID; otherwise it creates a new one and registers shape compat.
# Bumping var.force_image_generation changes display_name, forcing a
# fresh CreateImage on the next apply.
data "external" "talos_image" {
  program = ["bash", "${path.module}/../../../scripts/oci-image-create-or-find.sh"]

  query = {
    compartment_ocid = var.compartment_ocid
    display_name     = local.image_display_name
    source_uri       = local.image_source_uri
    oci_profile      = var.account_key
    shape            = local.image_primary_shape
  }

  # Must not run until the staged object exists in Object Storage. When
  # stage_local_upload is false the list is empty, so this is harmless.
  depends_on = [oci_objectstorage_object.talos_qcow2]
}

locals {
  image_ocid = data.external.talos_image.result.image_ocid
}

# Legacy resources retired: the native oci_core_image and the separate
# oci_core_shape_management calls were superseded by the CLI-driven
# data.external above. destroy = true so tofu removes them from OCI
# the first apply after migration — keeping them around would block
# re-creation on a force_image_generation bump (display_name collision).
removed {
  from = oci_core_image.talos
  lifecycle { destroy = true }
}

removed {
  from = oci_core_shape_management.talos_compat
  lifecycle { destroy = true }
}
