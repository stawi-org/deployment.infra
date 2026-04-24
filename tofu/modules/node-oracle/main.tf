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
    assign_ipv6ip          = var.assign_ipv6
    hostname_label         = var.name
    skip_source_dest_check = true
  }

  source_details {
    source_type = "image"
    source_id   = var.image_id
    # OCI A1.Flex requires boot volume ≥ 50 GB and the Talos factory
    # QCOW2 reports 47 GB which CreateInstance rejects. Operator wants
    # 200 GB — comfortable headroom for image cache + ephemeral
    # container-writable-layer + etcd snapshots. OCI always-free tier
    # covers up to 200 GB of boot volume across all instances, so no
    # charge for this.
    boot_volume_size_in_gbs = 200
  }

  metadata = {
    user_data = var.user_data
  }
}

data "oci_core_vnic_attachments" "this" {
  compartment_id = var.compartment_ocid
  instance_id    = oci_core_instance.this.id
}

data "oci_core_vnic" "primary" {
  vnic_id = data.oci_core_vnic_attachments.this.vnic_attachments[0].vnic_id
}

locals {
  private_ip = oci_core_instance.this.private_ip
  ipv6       = try(data.oci_core_vnic.primary.ipv6addresses[0], null)

  derived_labels = merge(
    var.labels,
    {
      "topology.kubernetes.io/region" = var.region
      "topology.kubernetes.io/zone"   = lower(replace(var.availability_domain, ":", "-"))
      "node.antinvestor.io/provider"  = "oracle"
      "node.antinvestor.io/account"   = var.account_key
      "node.antinvestor.io/role"      = var.role
    },
    var.role == "controlplane" ? {
      "node-role.kubernetes.io/control-plane" = ""
      } : {
      "node-role.kubernetes.io/worker" = ""
    }
  )
  derived_annotations = merge(
    var.annotations,
    {
      "node.antinvestor.io/shape"               = var.shape
      "node.antinvestor.io/availability-domain" = var.availability_domain
      "node.antinvestor.io/provider"            = "oracle"
      "node.antinvestor.io/account"             = var.account_key
      "node.antinvestor.io/role"                = var.role
    }
  )
}
