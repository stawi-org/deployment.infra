# tofu/modules/oracle-account-infra/main.tf
terraform {
  required_providers {
    oci   = { source = "oracle/oci", configuration_aliases = [oci] }
    talos = { source = "siderolabs/talos" }
  }
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.compartment_ocid
}

locals {
  available_ads = data.oci_identity_availability_domains.this.availability_domains[*].name
  # Resolve each node's availability_domain_index to the actual AD name.
  # Clamp to the last available AD so an out-of-range index in a
  # smaller-than-expected region (e.g. single-AD Marseille) still
  # resolves to a real AD instead of failing plan.
  #
  # Auto-fall-through on capacity exhaustion was attempted via OCI's
  # Compute Capacity Report resource but pure tofu can't make it work:
  # the report is a `resource` (not a `data` source), so its
  # available_count is unknown at plan time, and tofu's for-if filter
  # rejects unknown booleans. Workarounds (try/coalesce) don't help
  # because unknown != missing. Fall-through on OOC requires either
  # an external CLI call (data "external") or a script wrapper —
  # neither is acceptable as "pure tofu". Operators handle OOC by
  # editing availability_domain_index in nodes.yaml and re-applying.
  per_node_ad = {
    for k, v in var.nodes :
    k => local.available_ads[min(v.availability_domain_index, length(local.available_ads) - 1)]
  }
}
