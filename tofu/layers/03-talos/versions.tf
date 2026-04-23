# tofu/layers/03-talos/versions.tf
terraform {
  required_version = ">= 1.10"
  required_providers {
    talos = {
      source  = "siderolabs/talos"
      version = "0.11.0-beta.1"
    }
    oci = {
      source  = "oracle/oci"
      version = "~> 8.0"
    }
    null = {
      source = "hashicorp/null"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
