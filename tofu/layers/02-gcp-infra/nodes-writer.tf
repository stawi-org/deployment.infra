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
              # Drop prior provider_data then re-add; omni_machine_id is
              # re-injected only when gce_unique_id is unchanged so a
              # destroy/create (force reinstall) does not pin a ghost UUID.
              {
                for pk, pv in try(module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data, {}) :
                pk => pv if pk != "omni_machine_id"
              },
              {
                gce_instance_id        = node.id
                gce_self_link          = node.self_link
                gce_unique_id          = node.gce_unique_id
                machine_type           = node.machine_type
                zone                   = node.zone
                region                 = node.region
                preemptible            = node.preemptible
                ipv4                   = node.ipv4
                public_ipv4            = node.public_ipv4
                private_ipv4           = node.private_ipv4
                image_apply_generation = try(module.gcp_account[each.key].nodes[node_key].image_apply_generation, node.gce_unique_id)
                status                 = "running"
                discovered_at = try(
                  module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data.discovered_at,
                  timestamp(),
                )
              },
              # Preserve Omni pin only across STOP/start (same unique id).
              (
                try(module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data.gce_unique_id, "") == node.gce_unique_id
                && try(module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data.omni_machine_id, "") != ""
                ) ? {
                omni_machine_id = module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data.omni_machine_id
              } : {},
            )
          },
        )
      }, {})
    },
  )

  depends_on = [module.gcp_account]
}
