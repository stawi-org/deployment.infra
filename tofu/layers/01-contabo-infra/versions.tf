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
    # Keeper-only: the DNS records this layer used to manage were moved
    # to layer 03, but the resources still sit in this layer's state
    # until the next apply destroys them. Dropping the provider here
    # prevents tofu from refreshing those state entries, which errors
    # out the plan with "failed to make http request". Remove on a
    # follow-up commit once layer 01's state no longer lists any
    # cloudflare_dns_record resources.
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "contabo" {
  for_each             = toset(local.contabo_account_keys_from_state)
  alias                = "account"
  oauth2_client_id     = local.contabo_auth_from_module[each.key].oauth2_client_id
  oauth2_client_secret = local.contabo_auth_from_module[each.key].oauth2_client_secret
  oauth2_user          = local.contabo_auth_from_module[each.key].oauth2_user
  oauth2_pass          = local.contabo_auth_from_module[each.key].oauth2_pass
}
