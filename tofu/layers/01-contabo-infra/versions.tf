# tofu/layers/01-contabo-infra/versions.tf
terraform {
  required_version = ">= 1.10"
  required_providers {
    contabo = {
      source  = "contabo/contabo"
      version = "~> 0.1.42"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0-beta.1"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "contabo" {
  for_each             = toset(local.contabo_account_keys_from_state)
  alias                = "account"
  oauth2_client_id     = local.contabo_auth_from_module[each.key].oauth2_client_id
  oauth2_client_secret = local.contabo_auth_from_module[each.key].oauth2_client_secret
  oauth2_user          = local.contabo_auth_from_module[each.key].oauth2_user
  oauth2_pass          = local.contabo_auth_from_module[each.key].oauth2_pass
}
