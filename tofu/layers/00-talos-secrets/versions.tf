# tofu/layers/00-talos-secrets/versions.tf
terraform {
  required_version = ">= 1.10"
  required_providers {
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
