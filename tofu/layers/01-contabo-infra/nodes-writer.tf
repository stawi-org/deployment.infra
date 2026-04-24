# tofu/layers/01-contabo-infra/nodes-writer.tf
#
# After apply, merge each Contabo node's observed provider_data
# (instance_id, ipv4, ipv6, image_apply_generation) into the
# operator-declared node entry in nodes.yaml and write it back to R2.
#
# nodes.yaml is the single evolving source of truth per account:
#   - Operator edits declarative fields (role, product_id, labels, ...)
#     via providers/config/contabo/<acct>.yaml + upload-inventory.yml.
#   - Tofu writes back observed fields under .nodes[<key>].provider_data
#     on every successful apply.
# Downstream readers (imports.tf here, layer 03) take both out of the
# same file.

module "contabo_nodes_writer" {
  for_each            = toset(local.contabo_account_keys_from_state)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "contabo"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_nodes = true
  nodes_content = merge(
    # Keep the operator's declarative fields that came in via the
    # local sync. module.contabo_account_state.nodes is a decoded
    # read of nodes.yaml — its shape is { nodes = {...} }, annotated
    # with labels/annotations/etc. at the account level.
    try(module.contabo_account_state[each.key].nodes, {}),
    {
      nodes = {
        for node_key, node_module in module.nodes :
        node_key => merge(
          # Declarative entry exactly as the operator wrote it.
          try(module.contabo_account_state[each.key].nodes.nodes[node_key], {}),
          # Observed fields — overwrite on every apply so the file is
          # always current.
          {
            provider_data = {
              contabo_instance_id    = node_module.instance_id
              product_id             = node_module.product_id
              region                 = node_module.region
              ipv4                   = node_module.ipv4
              ipv6                   = node_module.ipv6
              image_apply_generation = node_module.image_apply_generation
              status                 = "running"
              discovered_at          = timestamp()
            }
          },
        )
        if node_module.account_key == each.key
      }
    },
  )

  depends_on = [module.nodes]
}
