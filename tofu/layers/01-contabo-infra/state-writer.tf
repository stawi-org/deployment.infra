# tofu/layers/01-contabo-infra/state-writer.tf
#
# One writer module per Contabo account. `state_content` captures what we
# observed about each node's provider-side state; layer 03 owns talos_state
# in its own sibling file (talos-state.yaml).

module "contabo_account_state_writer" {
  for_each       = toset(local.contabo_account_keys_from_state)
  source         = "../../modules/node-state"
  provider_name  = "contabo"
  account        = each.key
  age_recipients = split(",", var.age_recipients)

  write_state = true
  state_content = {
    provider = "contabo"
    account  = each.key
    nodes = {
      for node_key, node_module in module.nodes :
      node_key => {
        provider_data = {
          contabo_instance_id = node_module.instance_id
          product_id          = node_module.product_id
          region              = node_module.region
          ipv4                = node_module.ipv4
          ipv6                = node_module.ipv6
          status              = "running"
          discovered_at       = timestamp()
        }
      }
      if node_module.account_key == each.key
    }
  }

  depends_on = [module.nodes]
}
