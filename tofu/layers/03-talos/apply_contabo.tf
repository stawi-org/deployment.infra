# tofu/layers/03-talos/apply_contabo.tf
#
# Same apply-or-upgrade script as CPs (apply.tf), parameterised for
# Contabo workers.

resource "local_sensitive_file" "worker_machine_config" {
  for_each             = local.direct_contabo_worker_nodes
  content              = data.talos_machine_configuration.worker[each.key].machine_configuration
  filename             = "${local.apply_stage_dir}/worker/${each.key}.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

resource "null_resource" "apply_worker_contabo_config" {
  for_each = local.direct_contabo_worker_nodes

  triggers = {
    config_hash            = local_sensitive_file.worker_machine_config[each.key].content_sha256
    target_version         = var.talos_version
    image_apply_generation = each.value.image_apply_generation
  }

  depends_on = [
    local_sensitive_file.worker_machine_config,
    local_sensitive_file.talosconfig,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      NODE_IP             = each.value.ipv4
      NODE_NAME           = each.key
      TARGET_VERSION      = var.talos_version
      INSTALLER_URL       = local.installer_url
      MACHINE_CONFIG_FILE = local_sensitive_file.worker_machine_config[each.key].filename
      TALOSCONFIG_FILE    = local_sensitive_file.talosconfig.filename
    }
    command = "${path.module}/../../../scripts/talos-apply-or-upgrade.sh"
  }
}
