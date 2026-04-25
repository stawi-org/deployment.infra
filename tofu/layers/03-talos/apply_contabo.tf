# tofu/layers/03-talos/apply_contabo.tf
#
# Same apply-or-upgrade script as CPs (apply.tf), parameterised for
# Contabo workers. OCI / onprem workers don't exist yet; when they do,
# add an analogous null_resource keyed by their direct_*_worker_nodes
# map.

resource "null_resource" "apply_worker_contabo_config" {
  for_each = local.direct_contabo_worker_nodes

  triggers = {
    config_hash            = sha256(data.talos_machine_configuration.worker[each.key].machine_configuration)
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
      MACHINE_CONFIG = data.talos_machine_configuration.worker[each.key].machine_configuration
      TALOSCONFIG    = local.talosconfig_yaml
    }
    command = "${path.module}/../../../scripts/talos-apply-or-upgrade.sh"
  }
}
