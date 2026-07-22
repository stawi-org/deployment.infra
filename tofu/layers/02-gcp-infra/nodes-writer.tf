# tofu/layers/02-gcp-infra/nodes-writer.tf
#
# Mirrors layer 02-oracle-infra's nodes-writer: merges each GCE node's
# observed provider_data (gce_instance_id, machine_type, zone, IPs, etc.)
# into the operator-declared entry in nodes.yaml and writes it back.
# nodes.yaml is the evolving source of truth per account.

module "gcp_nodes_writer" {
  for_each            = toset(local.gcp_account_keys)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "gcp"
  account             = each.key

  write_nodes = true
  nodes_content = merge(
    try(module.gcp_account_state[each.key].nodes, {}),
    {
      nodes = try({
        for node_key, node in module.gcp_account[each.key].nodes_state :
        node_key => merge(
          try(module.gcp_account_state[each.key].nodes.nodes[node_key], {}),
          {
            # Merge so out-of-band pins (omni_machine_id from
            # reconcile-omni-machine-ids) survive tofu rewrites.
            provider_data = merge(
              try(module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data, {}),
              {
                gce_instance_id        = node.id
                gce_self_link          = node.self_link
                machine_type           = node.machine_type
                zone                   = node.zone
                region                 = node.region
                preemptible            = node.preemptible
                ipv4                   = node.ipv4
                public_ipv4            = node.public_ipv4
                private_ipv4           = node.private_ipv4
                image_apply_generation = try(module.gcp_account[each.key].nodes[node_key].image_apply_generation, node.id)
                status                 = "running"
                discovered_at          = timestamp()
              },
            )
          },
        )
      }, {})
    },
  )

  depends_on = [module.gcp_account]
}
