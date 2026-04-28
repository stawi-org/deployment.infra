# tofu/modules/oracle-account-infra/image.tf
#
# Custom Talos image creation on OCI. The OCI REST API does NOT expose
# `launchOptions` on CreateImage or UpdateImage — not via the CLI, not
# via raw REST, not via any SDK. The only place an image's launch
# options can be pinned is via an `image_metadata.json` embedded
# alongside the qcow2 in a `.oci` archive (plain tar). OCI auto-
# detects the archive on import and reads `externalLaunchOptions`
# (UEFI_64 + fully-paravirtualized virtio + pvEncryption) as the
# image's defaults — exactly what Talos arm64 on A1.Flex needs
# (kernel presents the boot volume at /dev/sda via virtio-scsi; with
# the default ISCSI bootVolumeType Talos sees no block device and
# hangs on `lstat /dev/sda: no such file or directory`).
#
# The workflow's "Stage Talos .oci archive" step builds the archive
# with Talos's exact published metadata schema (version 2, including
# the load-bearing `launchOptionsSource` + `additionalMetadata.
# shapeCompatibilities` fields). An earlier attempt at this approach
# (commits 1cd16d3 → 1e61ffd) used a malformed schema (version: "1.0"
# string, missing launchOptionsSource, wrong shape-compat path),
# which OCI silently rejected — leading to the false conclusion in
# 548ad33 that "OCI doesn't read the metadata". OCI does read it; the
# archive just has to be valid.
#
# launch_mode is deliberately omitted on oci_core_image: OCI computes
# it from the archive's embedded metadata at import time and reports
# it back into state. Setting any preset would override the auto-
# detection and re-introduce the wrong defaults.
#
# Source URI precedence:
#   1. var.talos_image_source_uri — operator-pinned URL.
#   2. Staged upload from var.talos_qcow2_local_path — the workflow
#      builds a .oci archive and uploads it to a per-account public-
#      read bucket.
#   3. Live factory URL — last-ditch fallback; OCI 400s on external
#      HTTPS but leaves local dev able to plan.
#
# Bumping var.force_image_generation replaces the image (forces a
# fresh CreateImage + re-registration of shape compat on next apply).

resource "terraform_data" "image_generation" {
  triggers_replace = var.force_image_generation
}

resource "talos_image_factory_schematic" "this" {
  schematic = templatefile("${var.shared_patches_dir}/../schematic.yaml.tftpl", {
    siderolink_url = var.omni_siderolink_url
  })
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
  # `.oci` extension reflects archive contents (qcow2 + image_metadata.
  # json wrapped in tar). Changing the suffix from the legacy `.qcow2`
  # forces a one-time destroy+create of oci_objectstorage_object on the
  # apply that lands this commit — necessary because the underlying
  # bytes are now a different format.
  image_object_name = "talos-${var.talos_version}-${talos_image_factory_schematic.this.id}-oracle-arm64.oci"

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

# Resource name `talos_qcow2` retained for state continuity even
# though contents are a .oci archive — tofu's resource address is
# in state, renaming would churn uploads for no user-visible benefit.
resource "oci_objectstorage_object" "talos_qcow2" {
  count        = local.stage_local_upload ? 1 : 0
  bucket       = oci_objectstorage_bucket.talos_images[0].name
  namespace    = data.oci_objectstorage_namespace.this.namespace
  object       = local.image_object_name
  source       = var.talos_qcow2_local_path
  content_type = "application/octet-stream"

  # OCI provider stores `source` in state as "<path> <mtime>" so every
  # fresh workflow run (new ephemeral runner, rebuilt archive with
  # fresh mtime) sees a diff and would force a re-upload of ~100 MB
  # plus a cascaded re-create of oci_core_image.talos. Content is
  # pinned by the object name (<version>-<schematic_id>-oracle-arm64.
  # oci) so a genuine content change lands as a different object
  # name — name-level replacement, not source-level. Ignore source
  # drift after create.
  lifecycle {
    ignore_changes = [source]
  }
}

resource "oci_core_image" "talos" {
  compartment_id = var.compartment_ocid
  display_name   = local.image_display_name

  image_source_details {
    source_type = "objectStorageUri"
    source_uri  = local.image_source_uri
    # source_image_type intentionally omitted. Setting it to "QCOW2"
    # tells OCI to treat the object as a raw qcow2 and ignore any
    # wrapping archive — which would skip reading the embedded
    # image_metadata.json. With no source_image_type OCI auto-detects
    # archive vs. raw and pulls launchOptions from the metadata when
    # it finds one.
  }

  # Wait for the staged archive to land in Object Storage before
  # CreateImage tries to fetch from the bucket URL. Harmless when
  # stage_local_upload is false (depends_on tolerates a 0-element list).
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

# OCI imports custom images with an empty compatible-shape list by
# default — even when the .oci archive's metadata declares
# shapeCompatibilities, that's documentation, not registration.
# Instances launched on a shape not in this table fail with:
#   400-InvalidParameter, Shape <X> is not valid for image <...>
# AddImageShapeCompatibilityEntry is idempotent (PUT semantics), so
# reruns are cheap. for_each over the distinct shapes used by var.nodes
# so adding a new shape family later just registers an extra entry.
resource "oci_core_shape_management" "talos_compat" {
  for_each       = toset([for n in values(var.nodes) : n.shape])
  compartment_id = var.compartment_ocid
  image_id       = local.image_ocid
  shape_name     = each.key
}
