output "auth" { value = local.auth_decoded }
output "nodes" { value = local.nodes_decoded }

# Diagnostic outputs — surface which inventory files were found so
# operators can debug "auth is null" after a fresh inventory sync.
output "inventory_keys_found" {
  value = sort(local.inventory_keys)
}
output "has_files" {
  value = {
    auth  = local.has_auth
    nodes = local.has_nodes
  }
}
