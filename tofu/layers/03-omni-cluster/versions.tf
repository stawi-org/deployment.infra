terraform {
  required_version = ">= 1.10"
  required_providers {
    omni = {
      # No official siderolabs/omni provider exists in the OpenTofu or Terraform
      # registry as of 2026-04. Using the community KittyKatt/omni provider which
      # is the only published option. Schema uses YAML-template resources instead
      # of the native HCL resources sketched in the migration plan.
      source  = "registry.terraform.io/KittyKatt/omni"
      version = "0.0.1-beta.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
  }
}
