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
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
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
  for_each             = local.contabo_accounts_effective
  alias                = "account"
  oauth2_client_id     = each.value.auth.oauth2_client_id
  oauth2_client_secret = each.value.auth.oauth2_client_secret
  oauth2_user          = each.value.auth.oauth2_user
  oauth2_pass          = each.value.auth.oauth2_pass
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}
