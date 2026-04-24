# tofu/layers/01-contabo-infra/imports.tf
#
# Dynamic imports driven by production/inventory/contabo/<acct>/state.yaml.
# Key is set only to the subset of nodes that *already have* a resolved
# instance ID in state.yaml — missing-state nodes plan as `create`.
#
# After apply, state.yaml is written back by this layer (state-writer.tf),
# so the next plan sees the full set and produces a zero-diff.

locals {
  # Bootstrap fallback: known existing Contabo instance IDs committed to
  # the repo for first-time apply. After the first successful apply,
  # state.yaml in R2 takes precedence (operator can delete the bootstrap
  # entries; they're ignored when state.yaml has the same node).
  bootstrap_instance_ids = try(
    yamldecode(file("${path.module}/../../shared/bootstrap/contabo-instance-ids.yaml")).contabo,
    {}
  )

  # Flat { "<node_key>" = "<instance_id>" }. State takes precedence over
  # bootstrap so the recorded post-apply ID always wins.
  contabo_existing_instance_ids = merge(
    # Bootstrap pass — populates only nodes the operator hardcoded.
    merge([
      for acct_key, nodes in local.bootstrap_instance_ids : {
        for node_key, node in nodes :
        node_key => try(node.contabo_instance_id, null)
        if try(node.contabo_instance_id, null) != null
      }
    ]...),
    # State pass — wins where both have the node.
    merge([
      for acct_key, node_map in local.contabo_state_from_module : {
        for node_key, node in node_map :
        node_key => try(node.provider_data.contabo_instance_id, null)
        if try(node.provider_data.contabo_instance_id, null) != null
      }
    ]...),
  )
}

import {
  for_each = local.contabo_existing_instance_ids
  to       = module.nodes[each.key].contabo_instance.this
  id       = each.value
}
