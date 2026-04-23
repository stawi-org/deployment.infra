# tofu/layers/03-talos/apply_contabo.tf

# Contabo worker nodes are publicly reachable like the Contabo control plane,
# so they use the same direct Talos apply path. OCI workers continue to use the
# bastion tunnel in apply_oracle.tf, and on-prem workers remain manual.

resource "terraform_data" "worker_contabo_config_hash" {
  for_each = local.contabo_worker_nodes
  input = {
    config                 = data.talos_machine_configuration.worker[each.key].machine_configuration
    generation             = var.force_talos_reapply_generation
    image_apply_generation = each.value.image_apply_generation
  }
}

resource "talos_machine_configuration_apply" "worker_contabo" {
  for_each                    = local.contabo_worker_nodes
  client_configuration        = data.terraform_remote_state.secrets.outputs.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker[each.key].machine_configuration
  node                        = each.value.ipv4
  endpoint                    = each.value.ipv4
  apply_mode                  = "reboot"

  lifecycle {
    replace_triggered_by = [terraform_data.worker_contabo_config_hash[each.key]]
  }
}
