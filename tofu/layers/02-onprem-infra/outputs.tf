# tofu/layers/02-onprem-infra/outputs.tf
output "nodes" {
  description = "On-prem node contracts consumed by layer 03."
  value = {
    for key, item in local.flattened_nodes : key => {
      name     = key
      role     = item.node.role
      region   = try(item.node.region, try(item.account.region, "unknown"))
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
          "topology.kubernetes.io/region" = try(item.node.region, try(item.account.region, "unknown"))
          "node.stawi.org/provider"       = "onprem"
          "node.stawi.org/account"        = item.account_key
          "node.stawi.org/role"           = item.node.role
          "node.stawi.org/apply-source"   = "manual"
          "node.stawi.org/managed-plane"  = "inventory"
          "node.stawi.org/latency-domain" = format(
            "onprem-%s",
            lower(replace(try(item.node.region, try(item.account.region, "unknown")), "/[^a-zA-Z0-9-]/", "-")),
          )
        },
        # See node-contabo/main.tf for why the worker side is empty:
        # NodeRestriction forbids kubelet from setting node-role.kubernetes.io/worker
        # and Talos's per-node Update() drops the whole label set on rejection.
        item.node.role == "controlplane" ? {
          "node-role.kubernetes.io/control-plane" = ""
        } : {},
      )
      derived_annotations = merge(
        item.node.annotations,
        {
          "node.stawi.org/account-description" = try(item.account.description, "")
          "node.stawi.org/site-ipv4-cidrs"     = join(",", try(item.account.site_ipv4_cidrs, []))
          "node.stawi.org/site-ipv6-cidrs"     = join(",", try(item.account.site_ipv6_cidrs, []))
          "node.stawi.org/provider"            = "onprem"
          "node.stawi.org/account"             = item.account_key
          "node.stawi.org/role"                = item.node.role
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
