# tofu/layers/03-talos/apply.tf
#
# Per-node Talos config + version reconciliation. The per-node
# provisioner shells out to scripts/talos-apply-or-upgrade.sh, which
# inspects each node's current stage and acts accordingly:
#
#   maintenance     →  apply-config --insecure   (clean install)
#   running, match  →  no-op                     (idempotent)
#   running, mismatch → talosctl upgrade --image (in-place upgrade)
#
# This single resource handles all four cases the operator described:
# fresh install, reinstall, idempotent re-runs, and version upgrades —
# without destroying running clusters.
#
# Configs are also written to R2 by per_node_configs_writer, so an
# operator can `aws s3 cp` to inspect what was generated:
#   production/inventory/<provider>/<account>/<talos-version>/<node>.yaml

locals {
  # Skip-list driven exclusion. Entries stay in controlplane_nodes /
  # cert SANs / DNS so the rest of the layer can model the node — they
  # just don't receive a `talosctl apply` pass on this run.
  direct_controlplane_nodes = {
    for k, v in local.controlplane_nodes : k => v
    if !contains(var.talos_apply_skip, k)
  }
  direct_contabo_worker_nodes = {
    for k, v in local.contabo_worker_nodes : k => v
    if !contains(var.talos_apply_skip, k)
  }

  # Per-CP DNS target — used only by talos_machine_bootstrap, which
  # MUST use mTLS (the BootstrapEtcd RPC requires authentication via
  # the cluster's client cert). Each CP's cert SANs include
  # cp-<N>.<zone>, so dialing that name validates regardless of
  # whether the node's public IP is on-NIC or NAT'd.
  cp_apply_target = length(var.cp_dns_zones) > 0 ? {
    for i, k in local.cp_sorted_keys :
    k => "${var.cp_dns_zones[0].cp_label}-${i + 1}.${var.cp_dns_zones[0].zone}"
    } : {
    for k, v in local.controlplane_nodes : k => v.ipv4
  }

  # Multi-arch factory installer URL — same schematic id picks the
  # right arch via the OCI manifest list, so Contabo amd64 and OCI
  # arm64 both resolve from this one base URL.
  installer_url = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}"

  # Talosconfig string used by the apply-or-upgrade script to talk
  # mTLS to running nodes (version checks, upgrades).
  talosconfig_yaml = data.talos_client_configuration.this.talos_config
}

resource "null_resource" "apply_cp_config" {
  for_each = local.direct_controlplane_nodes

  triggers = {
    # Re-run when the rendered config changes (label/SAN/sysctl edit
    # flows through), when target Talos version changes (triggers an
    # upgrade), or after a disk wipe (forces fresh maintenance-mode
    # apply). The script itself decides which path to take based on
    # the node's actual state at run time.
    config_hash            = sha256(data.talos_machine_configuration.cp[each.key].machine_configuration)
    target_version         = var.talos_version
    image_apply_generation = each.value.image_apply_generation
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      NODE_IP        = each.value.ipv4
      NODE_NAME      = each.key
      TARGET_VERSION = var.talos_version
      INSTALLER_URL  = local.installer_url
      MACHINE_CONFIG = data.talos_machine_configuration.cp[each.key].machine_configuration
      TALOSCONFIG    = local.talosconfig_yaml
    }
    command = "${path.module}/../../../scripts/talos-apply-or-upgrade.sh"
  }
}
