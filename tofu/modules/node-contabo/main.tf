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

# Enforce that contabo_instance.this.id is running var.image_id on the
# Contabo side. Runs once per image target change (trigger-keyed) and
# on first create.
resource "null_resource" "ensure_image" {
  # Fires ONLY on:
  #   (a) first creation of this instance (no OS yet — needs a real
  #       install). instance_id is fresh, so null_resource is new.
  #   (b) operator explicitly bumps var.force_reinstall_generation
  #       (disaster recovery / forced clean slate).
  #
  # Intentionally NOT keyed on var.image_id or the script hash —
  # bumping Talos versions is an UPGRADE, not a reinstall. An in-place
  # talosctl upgrade preserves etcd, volumes, and workload state; a
  # reinstall wipes all of that. The two paths must stay separate.
  triggers = {
    instance_id                = contabo_instance.this.id
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
      # Drives ensure-image.sh's failure-isolation policy: workers
      # warn-and-continue, controlplanes fail tofu. Keeps a single
      # bad VPS from blocking provisioning of the rest of the cluster.
      NODE_ROLE = var.role
      # MODE=verify on first-create: contabo_instance already provisioned
      # the disk with var.image_id via POST /instances — just confirm
      # Talos API is answering on :50000 so downstream layers see a
      # ready node.
      # MODE=reinstall when var.force_reinstall_generation is non-zero:
      # call Contabo's reinstall PUT directly and wait for Talos to
      # come back up. Wipes the disk.
      MODE = var.force_reinstall_generation > 0 ? "reinstall" : "verify"
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
