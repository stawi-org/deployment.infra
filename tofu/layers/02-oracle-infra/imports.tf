# tofu/layers/02-oracle-infra/imports.tf
#
# Adopt existing OCI instances on first apply in a fresh tofu state.
# Source: nodes.yaml's .nodes[<key>].provider_data.oci_instance_ocid —
# written back by the nodes-writer after every successful apply. On a
# fresh tofu state without a prior apply, the map is empty and tofu
# simply creates the instances.
#
# Once a resource is in tofu state, the import block is a no-op.

locals {
  # Flatten per-account nodes into a single map keyed by
  # "<acct>:<node>" (colon separator avoids ambiguity with hyphens).
  oracle_existing_instance_ocids = merge([
    for acct_key, node_map in local.oracle_nodes_from_module : {
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
