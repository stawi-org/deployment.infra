terraform {
  required_providers {
    oci    = { source = "oracle/oci", version = "~> 6.0" }
    random = { source = "hashicorp/random" }
  }
  required_version = ">= 1.7.0"
}
