locals {
  contabo_accounts_effective = {
    for acct_key in local.contabo_account_keys_from_state : acct_key => {
      auth        = local.contabo_auth_from_module[acct_key]
      labels      = try(module.contabo_account_state[acct_key].nodes.labels, {})
      annotations = try(module.contabo_account_state[acct_key].nodes.annotations, {})
      nodes       = local.contabo_nodes_from_module[acct_key]
    }
  }

  contabo_nodes = length(local.contabo_accounts_effective) > 0 ? merge([
    for account_key, account in local.contabo_accounts_effective : {
      for node_key, node in account.nodes : node_key => {
        account_key = account_key
        account     = account
        node_key    = node_key
        node        = node
      }
    }
  ]...) : {}
}

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}

# node-state: R2-backed inventory read. Populated initially by
# scripts/seed-inventory.sh; kept in sync by this layer's writers.
module "contabo_account_state" {
  for_each       = toset(local.contabo_account_keys_from_state)
  source         = "../../modules/node-state"
  provider_name  = "contabo"
  account        = each.key
  age_recipients = split(",", var.age_recipients)
}

locals {
  # Enumerated from the shared accounts.yaml manifest (Task 14).
  contabo_account_keys_from_state = local.accounts_manifest.contabo

  # Outputs of the module, per account — used by later tasks.
  contabo_auth_from_module = {
    for k, mod in module.contabo_account_state : k => try(mod.auth.auth, null)
  }
  contabo_nodes_from_module = {
    for k, mod in module.contabo_account_state : k => try(mod.nodes.nodes, {})
  }
  contabo_state_from_module = {
    for k, mod in module.contabo_account_state : k => try(mod.state.nodes, {})
  }
}
