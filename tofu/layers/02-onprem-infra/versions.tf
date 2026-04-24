# tofu/layers/02-onprem-infra/versions.tf
terraform {
  required_version = ">= 1.10"
  required_providers {
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
