# tofu/layers/02-oracle-infra/nodes-writer.tf
#
# Mirrors layer 01's nodes-writer: merges each OCI node's observed
# provider_data (oci_instance_ocid, ipv4 public, ipv6 GUA, etc.) into
# the operator-declared entry in nodes.yaml and writes it back. nodes.yaml
# is the evolving source of truth per account.

module "oracle_nodes_writer" {
  for_each            = toset(local.oracle_account_keys)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "oracle"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_nodes = true
  nodes_content = merge(
    try(module.oracle_account_state[each.key].nodes, {}),
    {
      nodes = try({
        for node_key, node in module.oracle_account[each.key].nodes_state :
        node_key => merge(
          try(module.oracle_account_state[each.key].nodes.nodes[node_key], {}),
          {
            provider_data = {
              oci_instance_ocid      = node.id
              shape                  = node.shape
              ocpus                  = node.ocpus
              memory_gb              = node.memory_gb
              region                 = node.region
              ipv4                   = node.ipv4
              ipv6                   = node.ipv6
              image_apply_generation = try(module.oracle_account[each.key].nodes[node_key].image_apply_generation, node.id)
              status                 = "running"
              discovered_at          = timestamp()
            }
          },
        )
      }, {})
    },
  )

  depends_on = [module.oracle_account]
}
