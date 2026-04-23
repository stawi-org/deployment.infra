locals {
  contabo_accounts_effective = length(var.contabo_accounts) > 0 ? var.contabo_accounts : (
    length(var.controlplane_nodes) > 0 ? {
      default = {
        auth = {
          oauth2_client_id     = var.contabo_client_id
          oauth2_client_secret = var.contabo_client_secret
          oauth2_user          = var.contabo_api_user
          oauth2_pass          = var.contabo_api_password
        }
        labels      = {}
        annotations = {}
        nodes = {
          for name, node in var.controlplane_nodes : name => {
            role        = "controlplane"
            product_id  = node.product_id
            region      = node.region
            labels      = {}
            annotations = {}
          }
        }
      }
    } : {}
  )

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
