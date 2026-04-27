# tofu/modules/node-oracle/main.tf
terraform {
  required_providers {
    oci = { source = "oracle/oci" }
  }
}

# Drops the legacy terraform_data.image_fingerprint from state without
# destroying anything. terraform_data has no real backend, so removed
# is a state-only edit. The replacement (reinstall_marker below) is a
# brand-new resource — its creation does NOT count as a replacement
# for replace_triggered_by purposes, so oci_core_instance is preserved
# across this migration.
removed {
  from = terraform_data.image_fingerprint
  lifecycle {
    destroy = false
  }
}

# Tracks ONLY the per-node reinstall-request hash. A Talos version
# bump intentionally does NOT trigger instance replacement here — we
# want the same in-place upgrade story Contabo gets (talosctl upgrade
# --image, no disk wipe, etcd survives). On OCI, source_details.source_id
# isn't ForceNew, so the provider plans an in-place update on the
# image OCID change but doesn't actually re-image a running disk;
# talosctl handles the on-disk Talos version swap. The instance
# state's source_id field drifts from the live boot image but
# functionally the cluster keeps running.
#
# The only path that recreates an OCI instance is now an explicit
# reinstall request file under .github/reconstruction/ — same
# semantics as Contabo's null_resource.ensure_image trigger.
resource "terraform_data" "reinstall_marker" {
  triggers_replace = {
    reinstall_request_hash = var.reinstall_request_hash
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

  # No instance launch_options. The image (created via the CLI script
  # in modules/oracle-account-infra with launchMode=CUSTOM and the
  # full Talos-prescribed launchOptions) already pins UEFI_64 +
  # fully-paravirtualized virtio. Instances inherit those defaults.

  # No user_data: the OCI Talos image boots into maintenance mode
  # when no cluster config is provided, listening on :50000 with a
  # self-signed cert. Layer 03's talos_machine_configuration_apply
  # auto-falls back to insecure mode for that first push (same flow
  # Contabo + onprem use). After the first apply Talos regenerates
  # its serving cert with cluster-CA-signed credentials and the
  # certSANs layer 03 declares — no chicken-and-egg between
  # user_data SANs and the connection endpoint.
  metadata = {}

  lifecycle {
    replace_triggered_by = [terraform_data.reinstall_marker]
    # availability_domain is resolved by the parent module's capacity
    # probe (oracle-account-infra/main.tf). It picks the AD with the
    # most current capacity, so the value can drift between plans even
    # without operator intent — without this, a capacity shift in
    # another AD would destroy+create a working instance to "move" it.
    # Ignore so the chosen-at-create AD sticks for the instance lifetime;
    # explicit reinstall is the only path that re-rolls AD selection.
    ignore_changes = [availability_domain]
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
    },
    # OCI's public IPv4 is NAT'd at the VCN gateway — the on-NIC
    # address is the private one, so kubelet auto-detects InternalIP
    # as the private IP and Flannel reads InternalIP for its public-ip
    # annotation. That breaks cross-cluster Flannel-VXLAN reachability
    # (other nodes try to tunnel to a non-routable RFC1918 address).
    # Force Flannel to use the actual public IP via the documented
    # public-ip-overwrite annotation. Annotations aren't restricted by
    # NodeRestriction admission, so kubelet sets it on its own node.
    local.public_ip != null && local.public_ip != "" ? {
      "flannel.alpha.coreos.com/public-ip-overwrite" = local.public_ip
    } : {},
    # IPv6 is on-NIC under OCI (no NAT66) so kubelet usually picks
    # the right address — but pinning it explicitly costs nothing and
    # documents the intent.
    local.ipv6 != null ? {
      "flannel.alpha.coreos.com/public-ipv6-overwrite" = local.ipv6
    } : {}
  )
}
