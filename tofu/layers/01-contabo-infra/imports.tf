# tofu/layers/01-contabo-infra/imports.tf
#
# Dynamic imports driven by production/inventory/contabo/<acct>/state.yaml.
# Key is set only to the subset of nodes that *already have* a resolved
# instance ID in state.yaml — missing-state nodes plan as `create`.
#
# After apply, state.yaml is written back by this layer (state-writer.tf),
# so the next plan sees the full set and produces a zero-diff.

locals {
  # Flat { "<node_key>" = "<instance_id>" } across all Contabo accounts.
  contabo_existing_instance_ids = merge([
    for acct_key, node_map in local.contabo_state_from_module : {
      for node_key, node in node_map :
      node_key => try(node.provider_data.contabo_instance_id, null)
      if try(node.provider_data.contabo_instance_id, null) != null
    }
  ]...)
}

import {
  for_each = local.contabo_existing_instance_ids
  to       = module.nodes[each.key].contabo_instance.this
  id       = each.value
}
