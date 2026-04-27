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

# Force every plan to re-probe AD capacity. oci_core_compute_capacity_report
# snapshots OCI's reply at create time and doesn't auto-refresh, so without
# this trigger plan N+1 would pick from plan N's stale data and we'd lose
# the whole point of probing. timestamp() always changes, which makes the
# report's diff show "must be replaced" on every plan — small noise in
# exchange for fresh capacity data driving each AD selection.
resource "terraform_data" "capacity_report_refresh" {
  triggers_replace = {
    refresh = timestamp()
  }
}

# One capacity report per (AD, node) — each probes whether the node's
# exact shape+config request can be satisfied right now in that AD.
# OCI returns available_count in shape units; for A1.Flex 1 unit = 1
# instance-of-this-shape-config, so available_count >= 1 means the
# node fits. Compartment-scoped, so the probe runs against the same
# tenancy quotas the actual launch will use.
locals {
  ad_node_pairs = flatten([
    for ad in local.available_ads : [
      for k, v in var.nodes : {
        key       = "${ad}::${k}"
        ad        = ad
        node_key  = k
        shape     = v.shape
        ocpus     = v.ocpus
        memory_gb = v.memory_gb
      }
    ]
  ])
}

resource "oci_core_compute_capacity_report" "ad_node" {
  for_each            = { for p in local.ad_node_pairs : p.key => p }
  compartment_id      = var.compartment_ocid
  availability_domain = each.value.ad

  shape_availabilities {
    instance_shape = each.value.shape
    instance_shape_config {
      ocpus         = each.value.ocpus
      memory_in_gbs = each.value.memory_gb
    }
  }

  lifecycle {
    replace_triggered_by = [terraform_data.capacity_report_refresh]
  }
}

locals {
  available_ads = data.oci_identity_availability_domains.this.availability_domains[*].name

  # The operator's hinted AD, clamped so an out-of-range index in a
  # smaller-than-expected region (e.g. single-AD Marseille) still
  # resolves to a real AD instead of erroring at plan time.
  per_node_hint_ad = {
    for k, v in var.nodes :
    k => local.available_ads[min(v.availability_domain_index, length(local.available_ads) - 1)]
  }

  # Every AD where this node's specific shape config currently has
  # capacity. Ordered same as available_ads (ascending by AD ordinal).
  per_node_ad_options = {
    for k, v in var.nodes : k => [
      for ad in local.available_ads :
      ad if oci_core_compute_capacity_report.ad_node["${ad}::${k}"].shape_availabilities[0].available_count >= 1
    ]
  }

  # Resolution: prefer hint if it has capacity, else newest-to-oldest of
  # what's available, else fall back to hint (will OOC at create — but
  # surfaces the problem honestly instead of silently placing the node
  # in an AD the operator didn't intend).
  per_node_ad = {
    for k, v in var.nodes : k => (
      contains(local.per_node_ad_options[k], local.per_node_hint_ad[k])
      ? local.per_node_hint_ad[k]
      : try(reverse(local.per_node_ad_options[k])[0], local.per_node_hint_ad[k])
    )
  }
}
