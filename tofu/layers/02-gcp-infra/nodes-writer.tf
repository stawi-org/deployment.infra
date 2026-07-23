# tofu/layers/02-gcp-infra/nodes-writer.tf
#
# Persist desired + observed node state to R2. When inventory was empty,
# desired_nodes is the OpenTofu default Spot pack — first apply seeds
# R2 without a separate seed script.

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
      labels = merge(
        { "node.stawi.org/account" = each.key },
        try(module.gcp_account_state[each.key].nodes.labels, {}),
      )
      annotations = merge(
        { "node.stawi.org/account-owner" = "platform" },
        try(module.gcp_account_state[each.key].nodes.annotations, {}),
      )
      nodes = try({
        for node_key, node in module.gcp_account[each.key].nodes_state :
        node_key => merge(
          # Desired fields from OpenTofu (defaults or prior inventory).
          try(module.gcp_account[each.key].desired_nodes[node_key], {}),
          # Prior inventory entry (operator edits win for labels/etc.).
          try(module.gcp_account_state[each.key].nodes.nodes[node_key], {}),
          {
            # Ensure role/size fields always present after a default seed.
            role         = try(module.gcp_account[each.key].desired_nodes[node_key].role, "worker")
            machine_type = node.machine_type
            zone         = node.zone
            boot_disk_gb = try(
              module.gcp_account_state[each.key].nodes.nodes[node_key].boot_disk_gb,
              try(module.gcp_account[each.key].desired_nodes[node_key].boot_disk_gb, 50),
            )
            preemptible = node.preemptible
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
                discovered_at = try(
                  module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data.discovered_at,
                  timestamp(),
                )
              },
            )
          },
        )
      }, {})
    },
  )

  depends_on = [module.gcp_account]
}
