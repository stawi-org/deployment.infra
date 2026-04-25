# tofu/layers/01-contabo-infra/outputs.tf
output "nodes" {
  description = "Map of all Contabo-hosted nodes with the cross-layer contract shape."
  value       = { for k, m in module.nodes : k => m.node }
}

output "cluster_reinstall_generation" {
  description = "Cluster-wide Contabo reinstall counter. Layer 03 watches this on talos_machine_bootstrap.replace_triggered_by — when it bumps, all 3 Contabo CPs were wiped together and the bootstrap RPC must re-fire against fresh etcd. Per-node reinstalls (per_node_force_reinstall_generation) do NOT bump this; those add a healthy node to a quorate cluster, not bootstrap a new one."
  value       = var.force_reinstall_generation
}

output "debug_inventory_has_files" {
  value = {
    for k, m in module.contabo_account_state : k => m.has_files
  }
}
output "debug_inventory_keys_found" {
  value = {
    for k, m in module.contabo_account_state : k => m.inventory_keys_found
  }
}
output "debug_auth_structure" {
  # Diagnostic-only. Values are either booleans, key lists, or length ints
  # — all derived from sensitive data but not themselves sensitive.
  # nonsensitive() strips the transitive sensitive marking for inspection.
  value = {
    for k, m in module.contabo_account_state : k => {
      auth_top_null   = nonsensitive(m.auth == null)
      has_auth_key    = nonsensitive(try(m.auth.auth, null) != null)
      auth_keys       = nonsensitive(try(sort(keys(m.auth.auth)), []))
      client_id_first = nonsensitive(try(substr(m.auth.auth.oauth2_client_id, 0, 4), "<null>"))
      client_sec_len  = nonsensitive(length(try(m.auth.auth.oauth2_client_secret, "")))
      user_first      = nonsensitive(try(substr(m.auth.auth.oauth2_user, 0, 3), "<null>"))
      pass_len        = nonsensitive(length(try(m.auth.auth.oauth2_pass, "")))
    }
  }
}
