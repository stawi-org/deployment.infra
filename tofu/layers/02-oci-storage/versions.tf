# tofu/layers/02-oci-storage/versions.tf
terraform {
  required_providers {
    oci  = { source = "oracle/oci", version = "~> 6.0" }
    aws  = { source = "hashicorp/aws", version = "~> 5.0" }
    sops = { source = "carlpett/sops", version = "~> 1.0" }
  }
  required_version = ">= 1.7.0"
}
