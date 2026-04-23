# tofu/layers/02-onprem-infra/outputs.tf
output "nodes" {
  description = "On-prem worker node contracts consumed by layer 03."
  value = {
    for key, item in local.flattened_nodes : key => {
      name     = key
      role     = item.node.role
      provider = "onprem"
      ipv4     = try(item.node.ipv4, null)
      ipv6     = try(item.node.ipv6, null)

      talos_endpoint = (
        try(item.node.ipv4, null) != null ? "${item.node.ipv4}:50000" :
        try(item.node.ipv6, null) != null ? "[${item.node.ipv6}]:50000" :
        null
      )
      kubespan_endpoint = try(item.node.ipv6, null) != null ? item.node.ipv6 : try(item.node.ipv4, null)

      derived_labels = merge(
        {
          "topology.kubernetes.io/region"     = item.location.region
          "node.antinvestor.io/provider"      = "onprem"
          "node.antinvestor.io/location"      = item.location_key
          "node.antinvestor.io/apply-source"  = "manual"
          "node.antinvestor.io/managed-plane" = "inventory"
        },
        item.node.labels,
      )
      derived_annotations = merge(
        {
          "node.antinvestor.io/location-description" = item.location.description
          "node.antinvestor.io/site-ipv4-cidrs"      = join(",", item.location.site_ipv4_cidrs)
          "node.antinvestor.io/site-ipv6-cidrs"      = join(",", item.location.site_ipv6_cidrs)
        },
        item.node.annotations,
      )

      instance_id         = key
      bastion_id          = null
      account_key         = item.location_key
      config_apply_source = "manual"
      image_apply_generation = md5(jsonencode({
        location = item.location_key
        node     = item.node
      }))
    }
  }
}
