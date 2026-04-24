# tofu/layers/01-contabo-infra/imports.tf
#
# Adopt existing Contabo instances on first apply in a fresh tofu state.
# Sources, highest-priority first:
#   1. nodes.yaml's .nodes[<key>].provider_data.contabo_instance_id —
#      written back by nodes-writer after every successful apply.
#   2. shared/bootstrap/contabo-instance-ids.yaml — seeded once per
#      account for the very-first bootstrap before nodes.yaml has a
#      recorded ID.
#
# Once a resource is in tofu state, the import block is a no-op; tofu
# tracks the instance directly.

locals {
  # Bootstrap fallback: known existing Contabo instance IDs committed to
  # the repo for first-time apply. After the first successful apply,
  # nodes.yaml in R2 takes precedence.
  bootstrap_instance_ids = try(
    yamldecode(file("${path.module}/../../shared/bootstrap/contabo-instance-ids.yaml")).contabo,
    {}
  )

  # Flat { "<node_key>" = "<instance_id>" }. nodes.yaml wins where both
  # entries exist — the operator-written bootstrap is a fallback only.
  contabo_existing_instance_ids = merge(
    merge([
      for acct_key, nodes in local.bootstrap_instance_ids : {
        for node_key, node in nodes :
        node_key => try(node.contabo_instance_id, null)
        if try(node.contabo_instance_id, null) != null
      }
    ]...),
    merge([
      for acct_key, node_map in local.contabo_nodes_from_module : {
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
