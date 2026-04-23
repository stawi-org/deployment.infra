# tofu/layers/01-contabo-infra/dns.tf
#
# Publishes Cloudflare DNS for the control-plane endpoint across one or
# more zones. Each zone entry in var.cp_dns_zones produces:
#
#   - <label>.<zone>         — round-robin: one A per CP, one AAAA per CP.
#                              This is the canonical cluster endpoint
#                              clients use; round-robin DNS + matching
#                              certSAN lets kubectl/talosctl fail over
#                              between CPs if one is down.
#
#   - <label>-<N>.<zone>     — single-node: one A + one AAAA per CP,
#                              1-indexed by sorted node key. Only emitted
#                              when the zone's `indexed` flag is true,
#                              so secondary zones can publish just the
#                              single shared record for minimal footprint.
#
# All IPs come from live contabo_instance outputs — no static IPs in
# tfvars, and reinstalls propagate to DNS on next apply.

locals {
  cp_sorted_keys = sort(keys(module.nodes))

  # Shared round-robin record definition used by every zone.
  cp_shared_record_value = {
    ipv4 = compact([for k in local.cp_sorted_keys : module.nodes[k].node.ipv4])
    ipv6 = compact([for k in local.cp_sorted_keys : module.nodes[k].node.ipv6])
  }

  # Per-CP single-IP records — cp-1, cp-2, cp-3, ...
  # Reused in every zone that has indexed = true.
  cp_indexed_record_values = {
    for i, k in local.cp_sorted_keys :
    (i + 1) => {
      ipv4 = compact([module.nodes[k].node.ipv4])
      ipv6 = compact([module.nodes[k].node.ipv6])
    }
  }
}

module "cp_dns" {
  for_each = { for z in var.cp_dns_zones : z.zone => z }

  source      = "../../modules/cloudflare-dns"
  zone_id     = each.value.zone_id
  zone_suffix = each.value.zone
  records = merge(
    {
      (each.value.label) = local.cp_shared_record_value
    },
    each.value.indexed ? {
      for idx, rec in local.cp_indexed_record_values :
      "${each.value.label}-${idx}" => rec
    } : {},
  )
  proxied = false # Talos API + Kubernetes API are raw TCP; never proxy.
  ttl     = 60    # Short so failover/reinstall propagates quickly.
}
