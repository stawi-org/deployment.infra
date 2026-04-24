# tofu/layers/03-talos/dns.tf
#
# Cross-provider DNS publishing. Replaces the Contabo-only DNS that used
# to live in layer 01 — now any controlplane, regardless of provider,
# gets cp-<N> and participates in the cp.<zone> round-robin. Nodes
# labelled node.kubernetes.io/external-load-balancer="true" additionally
# land in prod.<zone>.
#
# Runs in layer 03 because that's the first layer with a global view of
# every node (layer 01 sees only Contabo; layer 02 sees only one cloud
# at a time). cert SANs are computed here too, so the CP machine config
# and the Cloudflare records share a single source of truth — add a
# zone, and both the DNS and the SANs update in the same apply.

locals {
  # ---- ALL CPs, ordered stably ---------------------------------------
  # Sorting by node_key makes the cp-<N> index deterministic across
  # applies even if node ordering in state changes. Contabo's
  # kubernetes-controlplane-api-* keys sort before OCI/on-prem keys, so
  # cp-1 stays pointed at the same Contabo node unless that node is
  # deleted.
  cp_sorted_keys = sort(keys(local.controlplane_nodes))

  cp_all_ipv4 = compact([
    for k in local.cp_sorted_keys : try(local.controlplane_nodes[k].ipv4, null)
  ])
  cp_all_ipv6 = compact([
    for k in local.cp_sorted_keys : try(local.controlplane_nodes[k].ipv6, null)
  ])

  # Per-CP 1-indexed records. Empty v4/v6 lists are fine — the
  # cloudflare-dns module flattens and simply skips them.
  cp_indexed_records = {
    for i, k in local.cp_sorted_keys :
    (i + 1) => {
      ipv4 = compact([try(local.controlplane_nodes[k].ipv4, null)])
      ipv6 = compact([try(local.controlplane_nodes[k].ipv6, null)])
    }
  }

  # ---- Nodes behind the public load balancer -------------------------
  # Filter by the external-load-balancer label regardless of role. A CP
  # and a worker can both be LB-ingress entrypoints; any node with the
  # label participates in prod.<zone>.
  lb_nodes = {
    for k, v in local.all_nodes_from_state : k => v
    if try(v.derived_labels["node.kubernetes.io/external-load-balancer"], "false") == "true"
  }
  lb_sorted_keys = sort(keys(local.lb_nodes))
  lb_all_ipv4 = compact([
    for k in local.lb_sorted_keys : try(local.lb_nodes[k].ipv4, null)
  ])
  lb_all_ipv6 = compact([
    for k in local.lb_sorted_keys : try(local.lb_nodes[k].ipv6, null)
  ])
  lb_has_any = length(local.lb_all_ipv4) + length(local.lb_all_ipv6) > 0

  # ---- apiserver + talosd cert SANs ---------------------------------
  # Every cp-* FQDN we'll publish, plus any operator-supplied extras.
  # prod-* is intentionally excluded — those front load-balancer workers,
  # not apiserver. Clients that want prod.<zone>:443 go through the LB's
  # own TLS termination (cert-manager inside the cluster).
  cp_cert_sans = distinct(concat(
    flatten([
      for z in var.cp_dns_zones : concat(
        ["${z.cp_label}.${z.zone}"],
        [for i, _ in local.cp_sorted_keys : "${z.cp_label}-${i + 1}.${z.zone}"],
      )
    ]),
    var.extra_cert_sans,
  ))
}

module "cluster_dns" {
  for_each = { for z in var.cp_dns_zones : z.zone => z }

  source      = "../../modules/cloudflare-dns"
  zone_id     = each.value.zone_id
  zone_suffix = each.value.zone

  records = merge(
    # cp.<zone> — round-robin across every CP
    {
      (each.value.cp_label) = {
        ipv4 = local.cp_all_ipv4
        ipv6 = local.cp_all_ipv6
      }
    },
    # cp-<N>.<zone> — per-CP
    {
      for idx, rec in local.cp_indexed_records :
      "${each.value.cp_label}-${idx}" => rec
    },
    # prod.<zone> — round-robin across LB-labelled nodes (if any)
    local.lb_has_any ? {
      (each.value.prod_label) = {
        ipv4 = local.lb_all_ipv4
        ipv6 = local.lb_all_ipv6
      }
    } : {},
  )

  proxied = false # Raw TCP required for talosctl (50000) and apiserver (6443).
  ttl     = 60    # Short so node replacements propagate quickly.
}
