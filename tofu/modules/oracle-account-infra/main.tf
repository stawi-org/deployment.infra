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
  available_ads = data.oci_identity_availability_domains.this.availability_domains[*].name
  # Resolve each node's ad_index into the actual AD name. Clamp to the
  # last available AD so a config like ad_index=2 in a single-AD region
  # still gets a valid name (the legacy AD-0) instead of a tofu error.
  # This favors "node lands somewhere" over "config rejected for AD that
  # doesn't exist" — operators can verify placement after-the-fact via
  # the node's display_name → AD mapping in OCI console.
  per_node_ad = {
    for k, v in var.nodes :
    k => local.available_ads[min(v.ad_index, length(local.available_ads) - 1)]
  }
}
