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
  }
}
