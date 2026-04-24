# tofu/layers/03-talos/per-node-configs-writer.tf
#
# For every node that receives a rendered Talos machine config in this
# layer, write it to R2 at:
#   production/inventory/<provider>/<account>/<talos_version>/<node>.yaml
#
# Old <talos_version>/ directories from earlier Talos versions are left
# alone (audit trail + rollback artifact). A version bump produces a
# fresh directory alongside without touching the old one.

locals {
  # Pick the right data source for each node's role: cp[] for
  # controlplane, worker[] for worker. contains(keys(...)) is more
  # reliable than try() across index failures — the index operation
  # errors BEFORE try can catch it. Decode the YAML-string output back
  # into a map so yamlencode in the writer emits it cleanly
  # (avoids double-escaping).
  per_node_configs = {
    for node_key, node in local.all_nodes_from_state :
    node_key => yamldecode(
      contains(keys(data.talos_machine_configuration.cp), node_key)
      ? data.talos_machine_configuration.cp[node_key].machine_configuration
      : data.talos_machine_configuration.worker[node_key].machine_configuration
    )
  }

  # Enumerate every (provider, account) pair that has at least one
  # node, so we can fan out one writer module per account. Filter the
  # global per_node_configs map down to that account's nodes.
  account_keys = toset([
    for node_key, node in local.all_nodes_from_state :
    "${node.provider}:${node.account}"
  ])

  per_node_configs_by_acct = {
    for acct_key in local.account_keys :
    acct_key => {
      for node_key, node in local.all_nodes_from_state :
      node_key => local.per_node_configs[node_key]
      if "${node.provider}:${node.account}" == acct_key
    }
  }
}

module "per_node_configs_writer" {
  for_each            = local.per_node_configs_by_acct
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = split(":", each.key)[0]
  account             = split(":", each.key)[1]
  age_recipients      = split(",", var.age_recipients)

  write_per_node_configs   = true
  talos_version            = var.talos_version
  per_node_configs_content = each.value
}
