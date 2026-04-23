locals {
  contabo_accounts_effective = var.contabo_accounts

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
