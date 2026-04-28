terraform {
  required_version = ">= 1.10"
  required_providers {
    contabo = {
      source  = "contabo/contabo"
      version = "~> 0.1"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
