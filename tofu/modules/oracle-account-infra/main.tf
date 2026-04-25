# tofu/modules/oracle-account-infra/main.tf
terraform {
  required_providers {
    oci      = { source = "oracle/oci", configuration_aliases = [oci] }
    talos    = { source = "siderolabs/talos" }
    external = { source = "hashicorp/external" }
  }
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  ad_0 = data.oci_identity_availability_domains.this.availability_domains[0].name
}
