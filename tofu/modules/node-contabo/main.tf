# tofu/modules/node-contabo/main.tf
terraform {
  required_providers {
    contabo = { source = "contabo/contabo" }
  }
}

# Two-phase lifecycle for Contabo-hosted Talos nodes, mirroring what
# contabo.py / Ansible have done for years:
#
#   INSTALL (disk wipe, fresh OS): happens when the instance is first
#     created, or when the operator explicitly asks for it (disaster
#     recovery, unrecoverable node, clean slate). See
#     null_resource.ensure_image below — only fires in those cases.
#
#   UPGRADE (in-place Talos bump, preserves etcd/disks/workloads): for
#     every normal var.talos_version change. Handled by layer 03's
#     talosctl upgrade path (TODO: implement). NOT by Contabo reinstall.
#
# The reason for the split: Contabo's /compute/instances PUT with a new
# image_id wipes the disk and takes minutes; it's destructive. Talos's
# own upgrade mechanism swaps the Talos binary in place while kubelet,
# etcd, and pods stay up — appropriate for routine version bumps.
#
# Provider caveat we have to work around: the contabo/contabo provider
# claims "updating image_id reinstalls" in its docs (resource_instance.go
# shouldReinstall + reinstall), but its PUT payload only includes fields
# that HasChange fires for. An image_id-only PUT is treated by Contabo
# as a metadata update — ~40s, disk untouched. That's why we use
# lifecycle.ignore_changes on image_id: we never let the provider try
# to "reinstall" via its broken path. All disk wipes go through
# ensure-image.sh which mirrors contabo.py's proven full-payload PUT.
resource "contabo_instance" "this" {
  display_name = var.name
  product_id   = var.product_id
  region       = var.region
  image_id     = var.image_id
  period       = 1

  lifecycle {
    # See module comment — the provider doesn't actually reinstall on
    # image_id change. Let null_resource.ensure_image own drift
    # correction; keep state here stable (pegged to first-create value).
    ignore_changes = [image_id]
  }
}

# Enforce that contabo_instance.this.id is running var.image_id on
# the Contabo side. Triggers re-run when the target image_id drifts —
# a new contabo_image UUID (from inventory regen) is the sole signal
# for a reinstall. ensure-image.sh compares Contabo's reported imageId
# to the target and PUTs a reinstall iff they differ; otherwise no-op.
resource "null_resource" "ensure_image" {
  triggers = {
    instance_id     = contabo_instance.this.id
    target_image_id = var.image_id
    # Bumping force_reinstall_generation re-keys the trigger map →
    # null_resource is replaced → ensure-image.sh runs with
    # FORCE_REINSTALL=1 and reinstalls the VPS regardless of the
    # current imageId. Decouples "force fleet reinstall" from the
    # heavyweight schematic-bump → regen-images-PR → merge → apply
    # round-trip. Routine reinstalls (image drift) still use the
    # target_image_id trigger.
    force_reinstall_generation = var.force_reinstall_generation
  }

  provisioner "local-exec" {
    interpreter = ["bash"]
    environment = {
      INSTANCE_ID           = contabo_instance.this.id
      TARGET_IMAGE_ID       = var.image_id
      CONTABO_CLIENT_ID     = var.contabo_client_id
      CONTABO_CLIENT_SECRET = var.contabo_client_secret
      CONTABO_API_USER      = var.contabo_api_user
      CONTABO_API_PASSWORD  = var.contabo_api_password
      # Worker failures warn-and-continue; CP failures fail tofu.
      NODE_ROLE = var.role
      # Set when the operator wants to force a reinstall without
      # changing the schematic. ensure-image.sh skips the imageId-
      # equality short-circuit and PUTs unconditionally when this
      # is "1".
      FORCE_REINSTALL = var.force_reinstall_generation > 1 ? "1" : "0"
    }
    command = "${path.module}/ensure-image.sh"
  }
}

locals {
  ipv4 = contabo_instance.this.ip_config[0].v4[0].ip
  ipv6 = try(contabo_instance.this.ip_config[0].v6[0].ip, null)

  derived_labels = merge(
    var.labels,
    {
      "topology.kubernetes.io/region" = var.region
      "node.antinvestor.io/provider"  = "contabo"
      "node.antinvestor.io/account"   = var.account_key
      "node.antinvestor.io/role"      = var.role
      "node.antinvestor.io/name"      = var.name
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
      "node.antinvestor.io/product-id" = var.product_id
      "node.antinvestor.io/provider"   = "contabo"
      "node.antinvestor.io/account"    = var.account_key
      "node.antinvestor.io/role"       = var.role
    }
  )
}
