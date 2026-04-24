# tofu/modules/node-oracle/main.tf
terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

# Tracks the image OCID that the instance should launch from. Bumps
# when var.image_id changes — e.g. oci_core_image.talos was replaced
# upstream (force_image_generation bump, launch_mode change, etc.).
#
# Why this indirection: the OCI provider does NOT mark
# source_details.source_id as ForceNew, so tofu happily plans an
# in-place update when image_id changes. OCI then 400s on the update
# with "Boot volume type in image's launchOptions is not compatible
# with boot volume type in instance's launchOptions." The trigger
# below + replace_triggered_by on the instance forces tofu to plan
# destroy+create instead, matching what OCI actually requires.
resource "terraform_data" "image_fingerprint" {
  triggers_replace = var.image_id
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
    subnet_id = var.subnet_id
    # Ephemeral public IPv4 — free in OCI's always-free tier, released
    # when the instance terminates. Lets the CI runner, cert-manager
    # (LE challenges), and kubectl users reach the node directly.
    # IPv6 is always a GUA in OCI (no NAT66), so enabling IPv6 already
    # gets a public v6 address.
    assign_public_ip       = true
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

  # Mirror the image's CUSTOM launch options — OCI accepts the instance
  # create only when these match the image-embedded launchOptions. The
  # bootstrap-time 400 "Boot volume type in image's launchOptions is
  # not compatible with boot volume type in instance's launchOptions"
  # was what blocked the EMULATED migration; being explicit here means
  # tofu doesn't rely on OCI's defaulting rules (which picked wrong).
  launch_options {
    boot_volume_type                    = "PARAVIRTUALIZED"
    firmware                            = "UEFI_64"
    is_consistent_volume_naming_enabled = true
    is_pv_encryption_in_transit_enabled = true
    network_type                        = "PARAVIRTUALIZED"
    remote_data_volume_type             = "PARAVIRTUALIZED"
  }

  metadata = {
    user_data = var.user_data
  }

  lifecycle {
    replace_triggered_by = [terraform_data.image_fingerprint]
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
  # Public IPv4 is the ephemeral addr assigned by OCI when
  # assign_public_ip=true; falls back to private if somehow absent so
  # the rest of the chain still has something to work with.
  public_ip  = try(oci_core_instance.this.public_ip, null)
  private_ip = oci_core_instance.this.private_ip
  ipv4       = local.public_ip != null && local.public_ip != "" ? local.public_ip : local.private_ip
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
