# tofu/layers/02-onprem-infra/main.tf
locals {
  account_node_maps = [
    for account_key, account in var.onprem_accounts : {
      for node_key, node in account.nodes : "${account_key}-${node_key}" => {
        account_key = account_key
        node_key    = node_key
        region      = coalesce(try(node.region, null), account.region)
        account     = account
        node        = node
      }
    }
  ]

  flattened_nodes = length(local.account_node_maps) > 0 ? merge(local.account_node_maps...) : {}
}

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}
