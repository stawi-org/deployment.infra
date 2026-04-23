# tofu/modules/node-oracle/main.tf
terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

# Direct image_id + user_data wiring — changes cause destroy+create of
# the instance (OCI doesn't support in-place re-image). Expect the
# worker to disappear and reappear on any Talos version bump. The
# tofu-reinstall workflow is the safe path for dispatching these.
resource "oci_core_instance" "this" {
  compartment_id      = var.compartment_ocid
  availability_domain = var.availability_domain
  display_name        = var.name
  shape               = var.shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  create_vnic_details {
    subnet_id              = var.subnet_id
    assign_public_ip       = false
    hostname_label         = var.name
    skip_source_dest_check = true
  }

  source_details {
    source_type = "image"
    source_id   = var.image_id
  }

  metadata = {
    user_data = var.user_data
  }
}

locals {
  private_ip = oci_core_instance.this.private_ip

  derived_labels = {
    "topology.kubernetes.io/region" = var.region
    "topology.kubernetes.io/zone"   = lower(replace(var.availability_domain, ":", "-"))
    "node.antinvestor.io/provider"  = "oracle"
    "node.antinvestor.io/account"   = var.account_key
  }
  derived_annotations = {
    "node.antinvestor.io/shape"               = var.shape
    "node.antinvestor.io/availability-domain" = var.availability_domain
  }
}
