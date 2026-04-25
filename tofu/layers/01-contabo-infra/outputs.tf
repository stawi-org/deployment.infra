# tofu/layers/01-contabo-infra/outputs.tf
output "nodes" {
  description = "Map of all Contabo-hosted nodes with the cross-layer contract shape."
  value       = { for k, m in module.nodes : k => m.node }
}

output "cluster_reinstall_marker" {
  description = "SHA1 of all scope=all reinstall requests under .github/reconstruction/. Layer 03 watches this on talos_machine_bootstrap.replace_triggered_by — when it changes, every Contabo CP got a wipe request together and the bootstrap RPC must re-fire against fresh etcd. Per-node (scope=selected) requests deliberately do NOT change this; those add a healthy node to a quorate cluster instead of bootstrapping a new one."
  value       = local.cluster_wide_reinstall_marker
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
