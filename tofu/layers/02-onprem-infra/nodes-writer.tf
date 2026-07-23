# tofu/layers/02-onprem-infra/nodes-writer.tf
#
# On-prem nodes have no cloud-provider observed state — operators own
# every field in nodes.yaml. This writer keeps the file shape consistent
# with Contabo / Oracle (all three accounts look the same downstream),
# re-emitting the declarative content verbatim plus a minimal
# provider_data stamp.

module "onprem_nodes_writer" {
  for_each            = toset(local.onprem_account_keys)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "onprem"
  account             = each.key

  write_nodes = true
  nodes_content = merge(
    try(module.onprem_account_state[each.key].nodes, {}),
    {
      nodes = {
        for node_key, node in try(module.onprem_account_state[each.key].nodes.nodes, {}) :
        node_key => merge(
          node,
          {
            provider_data = merge(
              try(node.provider_data, {}),
              {
                status = "declared"
                # Preserve prior stamp so R2 nodes.yaml is not rewritten every plan.
                discovered_at = try(
                  module.onprem_account_state[each.key].nodes.nodes[node_key].provider_data.discovered_at,
                  timestamp(),
                )
              },
            )
          },
        )
      }
    },
  )
}
