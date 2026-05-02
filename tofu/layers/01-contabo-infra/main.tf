locals {
  contabo_accounts_effective = {
    for acct_key in local.contabo_account_keys_from_state : acct_key => {
      auth        = local.contabo_auth_from_module[acct_key]
      labels      = try(module.contabo_account_state[acct_key].nodes.labels, {})
      annotations = try(module.contabo_account_state[acct_key].nodes.annotations, {})
      nodes       = local.contabo_nodes_from_module[acct_key]
    }
  }

  # Drop the conditional: merge([]...) is {} when the input list is
  # empty, so the whole expression naturally degenerates without the
  # ternary. The ternary previously broke type inference when the
  # true branch produced a typed object with known attributes (e.g.
  # contabo-bwire-node-1) and the false {} couldn't unify with it.
  contabo_nodes = merge([
    for account_key, account in local.contabo_accounts_effective : {
      for node_key, node in account.nodes : node_key => {
        account_key = account_key
        account     = account
        node_key    = node_key
        node        = node
      }
    }
  ]...)
}

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}

# node-state: R2-backed inventory read. Populated initially by
# scripts/seed-inventory.sh; kept in sync by this layer's writers.
module "contabo_account_state" {
  for_each            = toset(local.contabo_account_keys_from_state)
  source              = "../../modules/node-state"
  provider_name       = "contabo"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

locals {
  # Per-account state: this layer instance manages exactly one contabo
  # account, scoped by var.account_key. The downstream for_each blocks
  # (modules, providers, imports, writers) iterate over
  # local.contabo_account_keys_from_state, so they keep working unchanged
  # — just with a single entry. Resource addresses
  # (module.contabo_account_state["bwire"], module.nodes["contabo-bwire-node-1"],
  # etc.) stay valid for existing state.
  contabo_account_keys_from_state = [var.account_key]

  # Outputs of the module, per account — used by later tasks.
  contabo_auth_from_module = {
    for k, mod in module.contabo_account_state : k => try(mod.auth.auth, null)
  }
  contabo_nodes_from_module = {
    for k, mod in module.contabo_account_state : k => try(mod.nodes.nodes, {})
  }
}
