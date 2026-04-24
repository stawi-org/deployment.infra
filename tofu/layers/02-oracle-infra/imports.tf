locals {
  # Flatten per-account node state into a single map keyed by "acct_key:node_key"
  # (colon separator to avoid ambiguity with hyphenated account/node names).
  oracle_existing_instance_ocids = merge([
    for acct_key, node_map in local.oracle_state_from_module : {
      for node_key, node in node_map :
      "${acct_key}:${node_key}" => try(node.provider_data.oci_instance_ocid, null)
      if try(node.provider_data.oci_instance_ocid, null) != null
    }
  ]...)
}

import {
  for_each = local.oracle_existing_instance_ocids
  to       = module.oracle_account[split(":", each.key)[0]].module.node[split(":", each.key)[1]].oci_core_instance.this
  id       = each.value
}
