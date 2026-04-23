module "onprem_account_state_writer" {
  for_each       = toset(local.onprem_account_keys)
  source         = "../../modules/node-state"
  provider_name  = "onprem"
  account        = each.key
  age_recipients = split(",", var.age_recipients)

  write_state = true
  state_content = {
    provider = "onprem"
    account  = each.key
    nodes = {
      for node_key, node in local.onprem_nodes_from_module[each.key] :
      node_key => {
        provider_data = {
          role          = node.role
          region        = try(node.region, null)
          discovered_at = timestamp()
        }
      }
    }
  }
}
