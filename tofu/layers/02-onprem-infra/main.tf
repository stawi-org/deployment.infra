# tofu/layers/02-onprem-infra/main.tf
module "onprem_account_state" {
  for_each            = toset(local.onprem_account_keys)
  source              = "../../modules/node-state"
  provider_name       = "onprem"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

locals {
  # Per-account state: this layer instance manages exactly one on-prem
  # account, scoped by var.account_key. The downstream for_each blocks
  # iterate over local.onprem_account_keys, so they keep working
  # unchanged — just with a single entry. Resource addresses
  # (module.onprem_account_state["tindase"], etc.) stay valid for
  # existing state.
  onprem_account_keys = [var.account_key]
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
