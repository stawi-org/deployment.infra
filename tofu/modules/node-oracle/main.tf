# tofu/modules/node-oracle/main.tf
terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

# Tracks the image OCID + var.force_recreate_generation. Bumps when
# var.image_id changes upstream OR when an operator deliberately bumps
# the generation to force a clean recreate (e.g. NIC type can't be
# changed on a running instance — OCI accepts UpdateInstance with new
# launch_options but doesn't rebuild the VNIC, so the VM keeps booting
# with the old NIC type).
#
# The OCI provider marks neither source_details.source_id nor
# launch_options.* as ForceNew, so without this indirection tofu
# would plan an in-place update that lands silently broken.
resource "terraform_data" "image_fingerprint" {
  triggers_replace = {
    image_id            = var.image_id
    recreate_generation = var.force_recreate_generation
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

  # Pin per-instance network_type only. OCI's LaunchInstance API
  # treats most LaunchOptions fields (Firmware, BootVolumeType) as
  # NON-overridable when the image already declares them — setting
  # them 400s with "Overriding <Field> in LaunchOptions is not
  # supported". network_type IS overridable, and we have to set it
  # because A1.Flex defaults to VFIO (SR-IOV pass-through) for the
  # instance even when the image's launch_mode = PARAVIRTUALIZED says
  # virtio. Talos arm64 needs virtio-net (PARAVIRTUALIZED).
  launch_options {
    network_type = "PARAVIRTUALIZED"
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
