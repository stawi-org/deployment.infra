# tofu/modules/oracle-account-infra/image.tf
#
# Reuse-or-create for the OCI custom Talos image. The image is identified
# by display_name = "Talos <version> arm64 gen<gen>". On every apply we
# look it up; if it already exists, we use it. If not, we create it from
# an OCI Object Storage URL — OCI's CreateImage refuses external HTTPS.
# The workflow downloads the factory QCOW2 once to a local path
# (var.talos_qcow2_local_path) and tofu uploads it into a per-account
# public-read bucket managed by this module.
#
# Precedence for the CreateImage source URI:
#   1. var.talos_image_source_uri — operator-pinned URL (e.g. a pre-existing
#      community bucket). Skips the upload machinery entirely.
#   2. Staged upload from var.talos_qcow2_local_path — the normal path
#      when running in CI with the factory QCOW2 just downloaded.
#   3. Live factory URL — only works for non-OCI platforms; included as a
#      last-ditch fallback so local dev without either var set still has
#      a chance, even though OCI will 400 on it.
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

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  image_display_name = "Talos ${var.talos_version} arm64 gen${var.force_image_generation}"

  # Only stage (create bucket + upload) when the workflow pre-downloaded
  # the QCOW2 AND no operator-supplied URL pre-empts it.
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
  # cascaded re-create of oci_core_image.talos. The content is pinned
  # by the object name (<version>-<schematic_id>-oracle-arm64.qcow2) so
  # a genuine content change lands as a different object — name-level
  # replacement, not source-level. Ignore source drift after create.
  lifecycle {
    ignore_changes = [source]
  }
}

# Probe: list AVAILABLE images in the compartment matching the
# display_name. Excludes deleted images so a previous force-replace
# doesn't shadow the freshly-created one.
data "oci_core_images" "existing" {
  compartment_id = var.compartment_ocid
  display_name   = local.image_display_name
  state          = "AVAILABLE"
}

locals {
  # OCI provider returns null (not []) when no images match. Coerce to
  # an empty list so length() and indexing behave normally.
  existing_images = try(data.oci_core_images.existing.images, []) == null ? [] : try(data.oci_core_images.existing.images, [])
}

# Create only when no AVAILABLE image with this display_name exists. After
# the first apply this resource is count = 0 and tofu does not touch OCI.
resource "oci_core_image" "talos" {
  count          = length(local.existing_images) == 0 ? 1 : 0
  compartment_id = var.compartment_ocid
  display_name   = local.image_display_name
  launch_mode    = "PARAVIRTUALIZED"
  image_source_details {
    source_type       = "objectStorageUri"
    source_uri        = local.image_source_uri
    source_image_type = "QCOW2"
  }

  # Must wait for the staged object to be uploaded before CreateImage
  # attempts to fetch from the bucket URL. Harmless when stage_local_upload
  # is false — the list is empty and depends_on is a no-op.
  depends_on = [oci_objectstorage_object.talos_qcow2]

  lifecycle {
    # Pin recreation to deliberate generation bumps (or the explicit
    # force_image_generation knob). Ignore drift in image_source_details
    # once the image is created — OCI mutates/re-resolves the stored URL
    # internally and the provider surfaces it as a diff on every plan,
    # which (before ignore_changes) cascaded into an 8-minute image
    # re-import + downstream instance/shape_management replaces on
    # every apply. The image content is identified by the object name
    # (includes version+schematic id), so a genuine content change still
    # triggers force_image_generation → replace_triggered_by → replace.
    replace_triggered_by = [terraform_data.image_generation]
    ignore_changes       = [image_source_details]
  }
}

# Single source-of-truth OCID consumed by nodes.tf + shape compat below.
# Whether the image was freshly created or reused from a prior apply,
# callers don't care.
locals {
  image_ocid = (
    length(local.existing_images) > 0
    ? local.existing_images[0].id
    : oci_core_image.talos[0].id
  )
}

# OCI imports custom QCOW2 images with a conservative default compatible-
# shape list (basically none for non-Oracle images). Instances launched on
# a shape not in this list fail with:
#   400-InvalidParameter, Shape <X> is not valid for image <...>
# AddImageShapeCompatibilityEntry is idempotent (PUT semantics), so we
# can register unconditionally — reruns are cheap. Registering
# regardless of whether the image was just created or reused is also
# essential: a freshly-created image from a *failed prior apply* (state
# rolled back or resource orphaned) still needs the compat entries that
# the failed apply never got to write.
resource "oci_core_shape_management" "talos_compat" {
  for_each       = toset([for n in values(var.nodes) : n.shape])
  compartment_id = var.compartment_ocid
  image_id       = local.image_ocid
  shape_name     = each.key
}
