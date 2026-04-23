# tofu/modules/oracle-account-infra/image.tf
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

resource "oci_core_image" "talos" {
  compartment_id = var.compartment_ocid
  display_name   = "Talos ${var.talos_version} arm64 gen${var.force_image_generation}"
  launch_mode    = "PARAVIRTUALIZED"
  image_source_details {
    source_type       = "objectStorageUri"
    source_uri        = data.talos_image_factory_urls.this.urls.disk_image
    source_image_type = "QCOW2"
  }

  lifecycle {
    replace_triggered_by = [terraform_data.image_generation]
  }
}
