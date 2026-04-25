# tofu/layers/01-contabo-infra/nodes.tf
module "nodes" {
  for_each = local.contabo_nodes
  source   = "../../modules/node-contabo"

  name        = each.key
  role        = each.value.node.role
  account_key = each.value.account_key
  product_id  = each.value.node.product_id
  region      = each.value.node.region
  labels      = merge(each.value.account.labels, each.value.node.labels)
  annotations = merge(each.value.account.annotations, each.value.node.annotations)
  image_id    = contabo_image.talos[each.value.account_key].id

  # Used by null_resource.ensure_image in the module to call the
  # Contabo reinstall PUT directly (the contabo provider's own
  # update-in-place path doesn't actually re-image the disk; see
  # the module comment in modules/node-contabo/main.tf).
  contabo_client_id     = each.value.account.auth.oauth2_client_id
  contabo_client_secret = each.value.account.auth.oauth2_client_secret
  contabo_api_user      = each.value.account.auth.oauth2_user
  contabo_api_password  = each.value.account.auth.oauth2_pass

  # Effective generation = cluster-wide baseline + per-node override.
  # Bumping the cluster-wide variable wipes every CP in parallel;
  # bumping an entry in var.per_node_force_reinstall_generation wipes
  # only that node. See variables.tf for the surgical-recovery flow.
  force_reinstall_generation = var.force_reinstall_generation + lookup(var.per_node_force_reinstall_generation, each.key, 0)

  providers = { contabo = contabo.account[each.value.account_key] }
}
