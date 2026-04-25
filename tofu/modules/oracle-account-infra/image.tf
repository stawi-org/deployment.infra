# tofu/modules/oracle-account-infra/image.tf
#
# Custom Talos image creation on OCI. The OCI REST API does NOT expose
# `launchOptions` on CreateImage or UpdateImage — not via the CLI, not
# via raw REST, not via any SDK. The only place an image's launch
# options can be pinned is via an `image_metadata.json` embedded
# alongside the qcow2 in a `.oci` archive. OCI auto-detects the
# archive on import and reads `externalLaunchOptions` (UEFI_64,
# PARAVIRTUALIZED boot/network/remote-data volumes, pvEncryption) as
# the image's defaults — exactly what Talos arm64 on A1.Flex needs
# (kernel presents the boot volume at /dev/sda via virtio-scsi; with
# the default ISCSI bootVolumeType Talos sees no block device and
# hangs on `lstat /dev/sda: no such file or directory`).
#
# The tofu oci_core_image resource is used directly (not via a CLI
# shim). Its launch_options attribute is Computed-only — that's fine,
# because we're not setting it here; OCI computes it from the
# archive's embedded metadata at import time and reports it back
# into state.
#
# Source URI precedence:
#   1. var.talos_image_source_uri — operator-pinned URL.
#   2. Staged upload from var.talos_qcow2_local_path — the workflow
#      builds a .oci archive (qcow2 + image_metadata.json) and uploads
#      it to a per-account public-read bucket.
#   3. Live factory URL — last-ditch fallback; OCI 400s on external
#      HTTPS but leaves local dev able to plan.
#
# Bumping var.force_image_generation replaces the image (forces a
# fresh CreateImage + re-registration of shape compat on next apply).

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

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  image_display_name = "Talos ${var.talos_version} arm64 gen${var.force_image_generation}"

  # Only stage (create bucket + upload) when the workflow pre-built
  # the .oci archive AND no operator-supplied URL pre-empts it.
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

# Keeping the resource name `talos_qcow2` for state continuity even
# though the file is a .oci archive now — tofu's resource address is
# in state, renaming would churn uploads for no user-visible benefit.
resource "oci_objectstorage_object" "talos_qcow2" {
  count        = local.stage_local_upload ? 1 : 0
  bucket       = oci_objectstorage_bucket.talos_images[0].name
  namespace    = data.oci_objectstorage_namespace.this.namespace
  object       = local.image_object_name
  source       = var.talos_qcow2_local_path
  content_type = "application/octet-stream"

  # OCI provider stores `source` in state as "<path> <mtime>" so every
  # fresh workflow run (new ephemeral runner, rebuilt file with fresh
  # mtime) sees a diff and would force a re-upload of ~100 MB plus a
  # cascaded re-create of oci_core_image.talos. Content is pinned by
  # the object name (<version>-<schematic_id>-oracle-arm64.oci) so a
  # genuine content change lands as a different object — name-level
  # replacement, not source-level. Ignore source drift after create.
  lifecycle {
    ignore_changes = [source]
  }
}

resource "oci_core_image" "talos" {
  compartment_id = var.compartment_ocid
  display_name   = local.image_display_name

  # launch_mode = NATIVE keeps firmware at UEFI_64 (required for arm64)
  # and lets bootVolumeType be overridden at instance launch.
  # Empirically (verified via `oci compute image get --query launch-
  # options`):
  #   * launch_mode = NATIVE        → firmware=UEFI_64, bootVolumeType=ISCSI
  #   * launch_mode = PARAVIRTUALIZED → firmware=BIOS, bootVolumeType=PARAVIRT
  # On arm64 BIOS cannot boot, so PARAVIRTUALIZED is unusable. We pin
  # launch_mode = NATIVE for the right firmware and have the instance
  # override boot_volume_type and network_type to PARAVIRTUALIZED.
  launch_mode = "NATIVE"

  image_source_details {
    source_type       = "objectStorageUri"
    source_uri        = local.image_source_uri
    source_image_type = "QCOW2"
  }

  # Must wait for the staged object to be uploaded before CreateImage
  # attempts to fetch from the bucket URL. Harmless when
  # stage_local_upload is false.
  depends_on = [oci_objectstorage_object.talos_qcow2]

  lifecycle {
    # Recreate only on a deliberate force_image_generation bump.
    # Ignore image_source_details drift — OCI mutates the stored URL
    # internally after import and the provider surfaces that as a diff
    # on every plan. Without ignore_changes that would trigger an
    # 8-minute re-import on every apply.
    replace_triggered_by = [terraform_data.image_generation]
    ignore_changes       = [image_source_details]
  }
}

locals {
  image_ocid = oci_core_image.talos.id
}

# OCI imports custom QCOW2/OCI images with an empty compatible-shape
# list by default. Instances launched on a shape not in this list
# fail with:
#   400-InvalidParameter, Shape <X> is not valid for image <...>
# AddImageShapeCompatibilityEntry is idempotent (PUT semantics), so
# we register unconditionally on every apply — reruns are cheap.
resource "oci_core_shape_management" "talos_compat" {
  for_each       = toset([for n in values(var.nodes) : n.shape])
  compartment_id = var.compartment_ocid
  image_id       = local.image_ocid
  shape_name     = each.key
}
