terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws  = { source = "hashicorp/aws", version = "~> 5.70" }
    sops = { source = "carlpett/sops", version = "~> 1.1" }
  }
}
