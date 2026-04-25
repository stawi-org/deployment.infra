# tofu/layers/03-talos/apply.tf
#
# Per-node Talos config + version reconciliation. Each node's
# rendered config is staged to disk (so it doesn't blow ARG_MAX on
# the provisioner's env), then scripts/talos-apply-or-upgrade.sh
# inspects the node's stage and acts:
#
#   maintenance     →  apply-config --insecure   (clean install)
#   running, match  →  no-op                     (idempotent)
#   running, mismatch → talosctl upgrade --image (in-place upgrade)

locals {
  direct_controlplane_nodes = {
    for k, v in local.controlplane_nodes : k => v
    if !contains(var.talos_apply_skip, k)
  }
  direct_contabo_worker_nodes = {
    for k, v in local.contabo_worker_nodes : k => v
    if !contains(var.talos_apply_skip, k)
  }

  # Per-CP DNS target — used only by talos_machine_bootstrap (mTLS).
  cp_apply_target = length(var.cp_dns_zones) > 0 ? {
    for i, k in local.cp_sorted_keys :
    k => "${var.cp_dns_zones[0].cp_label}-${i + 1}.${var.cp_dns_zones[0].zone}"
    } : {
    for k, v in local.controlplane_nodes : k => v.ipv4
  }

  installer_url = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}"

  # Staging directory for the apply provisioner — written outside the
  # tofu working tree so init/format don't churn on it.
  apply_stage_dir = "${path.module}/.apply-stage"
}

# Talosconfig + per-node machine configs staged to disk so the
# provisioner can pass file PATHS rather than the file contents
# (which exceed Linux ARG_MAX as env vars).
resource "local_sensitive_file" "talosconfig" {
  content              = data.talos_client_configuration.this.talos_config
  filename             = "${local.apply_stage_dir}/talosconfig.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "local_sensitive_file" "cp_machine_config" {
  for_each             = local.direct_controlplane_nodes
  content              = data.talos_machine_configuration.cp[each.key].machine_configuration
  filename             = "${local.apply_stage_dir}/cp/${each.key}.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "null_resource" "apply_cp_config" {
  for_each = local.direct_controlplane_nodes

  triggers = {
    config_hash            = local_sensitive_file.cp_machine_config[each.key].content_sha256
    target_version         = var.talos_version
    image_apply_generation = each.value.image_apply_generation
  }

  depends_on = [
    local_sensitive_file.cp_machine_config,
    local_sensitive_file.talosconfig,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      NODE_IP             = each.value.ipv4
      NODE_NAME           = each.key
      TARGET_VERSION      = var.talos_version
      INSTALLER_URL       = local.installer_url
      MACHINE_CONFIG_FILE = local_sensitive_file.cp_machine_config[each.key].filename
      TALOSCONFIG_FILE    = local_sensitive_file.talosconfig.filename
    }
    command = "${path.module}/../../../scripts/talos-apply-or-upgrade.sh"
  }
}
