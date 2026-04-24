# tofu/layers/02-onprem-infra/outputs.tf
output "nodes" {
  description = "On-prem node contracts consumed by layer 03."
  value = {
    for key, item in local.flattened_nodes : key => {
      name     = key
      role     = item.node.role
      region   = coalesce(try(item.node.region, null), try(item.account.region, ""))
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
        item.node.labels,
        {
          "topology.kubernetes.io/region"     = coalesce(try(item.node.region, null), try(item.account.region, ""))
          "node.antinvestor.io/provider"      = "onprem"
          "node.antinvestor.io/account"       = item.account_key
          "node.antinvestor.io/role"          = item.node.role
          "node.antinvestor.io/apply-source"  = "manual"
          "node.antinvestor.io/managed-plane" = "inventory"
        },
        item.node.role == "controlplane" ? {
          "node-role.kubernetes.io/control-plane" = ""
          } : {
          "node-role.kubernetes.io/worker" = ""
        },
      )
      derived_annotations = merge(
        item.node.annotations,
        {
          "node.antinvestor.io/account-description" = try(item.account.description, "")
          "node.antinvestor.io/site-ipv4-cidrs"     = join(",", try(item.account.site_ipv4_cidrs, []))
          "node.antinvestor.io/site-ipv6-cidrs"     = join(",", try(item.account.site_ipv6_cidrs, []))
          "node.antinvestor.io/provider"            = "onprem"
          "node.antinvestor.io/account"             = item.account_key
          "node.antinvestor.io/role"                = item.node.role
        },
      )

      instance_id         = key
      bastion_id          = null
      account_key         = item.account_key
      config_apply_source = "manual"
      image_apply_generation = md5(jsonencode({
        account = item.account_key
        node    = item.node
      }))
    }
  }
}
