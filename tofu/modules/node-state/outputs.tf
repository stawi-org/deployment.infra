# local.*_decoded are defined in main.tf (added in the next commit).
# tofu validate fails on this module standalone until then.
output "auth" { value = local.auth_decoded }
output "nodes" { value = local.nodes_decoded }
output "state" { value = local.state_decoded }
output "talos_state" { value = local.talos_state_decoded }
output "machine_configs" { value = local.machine_configs_decoded }

# Diagnostic outputs — show which inventory files were found, useful for
# debugging "auth is null" and similar issues when seed step succeeded but
# the read side can't see the files yet.
output "inventory_keys_found" {
  value = sort(local.inventory_keys)
}
output "has_files" {
  value = {
    auth            = local.has_auth
    nodes           = local.has_nodes
    state           = local.has_state
    talos_state     = local.has_talos_state
    machine_configs = local.has_machine_configs
  }
}
