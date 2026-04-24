# tofu/layers/02-onprem-infra/main.tf
locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}

module "onprem_account_state" {
  for_each            = toset(local.accounts_manifest.onprem)
  source              = "../../modules/node-state"
  provider_name       = "onprem"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

locals {
  onprem_account_keys = local.accounts_manifest.onprem
  onprem_nodes_from_module = {
    for k, mod in module.onprem_account_state : k => try(mod.nodes.nodes, {})
  }

  # Full decoded nodes.yaml per account, used for account-level metadata
  # (description, region, labels, annotations, site_* cidrs if present).
  onprem_account_meta = {
    for k, mod in module.onprem_account_state : k => try(mod.nodes, {})
  }

  onprem_accounts_effective = {
    for k in local.onprem_account_keys : k => {
      nodes = local.onprem_nodes_from_module[k]
    }
  }

  flattened_nodes = merge([
    for acct_key, acct in local.onprem_accounts_effective : {
      for node_key, node in acct.nodes : "${acct_key}-${node_key}" => {
        account_key = acct_key
        node_key    = node_key
        node        = node
        account     = local.onprem_account_meta[acct_key]
      }
    }
  ]...)
}
