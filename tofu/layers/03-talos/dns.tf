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
  # applies even if node ordering in state changes. Provider prefixes
  # sort alphabetically (contabo-*, oci-*, onprem-*) so cp-1 stays
  # pointed at the same Contabo node unless that node is deleted.
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

  # ---- Workers with a public IP (eligible for per-worker DNS) --------
  # Same indexing pattern as CPs: alphabetical sort by node_key gives
  # worker-1, worker-2, ... stable across applies. Excludes workers
  # without any public address (KubeSpan-only on-prem) — they can't be
  # dialed from a CI runner so a DNS record would only invite confusion.
  workers_with_public_ip = {
    for k, v in local.worker_nodes : k => v
    if try(v.ipv4, "") != "" || try(v.ipv6, null) != null
  }
  worker_sorted_keys = sort(keys(local.workers_with_public_ip))

  worker_all_ipv4 = compact([
    for k in local.worker_sorted_keys : try(local.workers_with_public_ip[k].ipv4, null)
  ])
  worker_all_ipv6 = compact([
    for k in local.worker_sorted_keys : try(local.workers_with_public_ip[k].ipv6, null)
  ])

  worker_indexed_records = {
    for i, k in local.worker_sorted_keys :
    (i + 1) => {
      ipv4 = compact([try(local.workers_with_public_ip[k].ipv4, null)])
      ipv6 = compact([try(local.workers_with_public_ip[k].ipv6, null)])
    }
  }
  worker_has_any = length(local.worker_all_ipv4) + length(local.worker_all_ipv6) > 0

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
  # cp.<zone>          (round-robin, every CP carries it)
  # cp-<N>.<zone>      (per-CP, N is 1-based index in cp_sorted_keys)
  #
  # Per-CP names are required for talos_machine_configuration_apply,
  # which is a per-node RPC: each apply must dial the node it's
  # configuring, and TLS validates the dial target against a SAN. By
  # giving every CP both the round-robin name AND its own cp-<N>.<zone>,
  # tofu can address each one without relying on Talos's auto-discovery
  # of NIC-bound public IPs (which OCI's NAT'd ephemeral doesn't have).
  # No node IPs in this list — DNS records are tofu-managed and stable
  # under instance recreates. prod-* is excluded — those front the LB,
  # which has its own cert-manager TLS termination inside the cluster.
  cp_cert_sans = distinct(concat(
    [for z in var.cp_dns_zones : "${z.cp_label}.${z.zone}"],
    flatten([
      for z in var.cp_dns_zones : [
        for i, _ in local.cp_sorted_keys : "${z.cp_label}-${i + 1}.${z.zone}"
      ]
    ]),
    var.extra_cert_sans,
  ))

  # ---- worker apid cert SANs ----------------------------------------
  # worker-<N>.<zone>  (per-worker, N is 1-based index in
  #                     worker_sorted_keys)
  #
  # Same motivation as CPs but for the worker side: this layer's apply
  # path dials each worker individually to push its config, and TLS
  # validates the dial target against a SAN. Talos auto-populates SANs
  # from on-NIC interface addresses, so a Contabo worker's public IPv4
  # is covered for free. NAT'd providers (OCI: public IPv4 lives on the
  # NAT gateway, not the NIC) are NOT covered by auto-SANs — without
  # an explicit name in SANs, dialing the public IPv4 fails the TLS
  # handshake. Anchoring on a stable DNS name is preferred over patching
  # the ephemeral IP into SANs so the cert doesn't have to re-render
  # whenever an IP rotates (cert-rotation-on-IP-change is the failure
  # mode we keep hitting; see talos-apply-or-upgrade.sh's /etc/hosts
  # repinning logic for why ephemeral IPs are a tax we don't want).
  worker_cert_sans = distinct(flatten([
    for z in var.cp_dns_zones : [
      for i, _ in local.worker_sorted_keys : "${z.worker_label}-${i + 1}.${z.zone}"
    ]
  ]))
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
    # worker-<N>.<zone> — per-worker (only workers with a public IP).
    # Anchors the apply path's dial target to a stable name so an OCI
    # NAT'd worker (whose public IPv4 isn't on its NIC and so isn't in
    # Talos's auto-SAN list) can be reached without putting ephemeral
    # IPs into cert SANs. Also gives Contabo workers a friendly name —
    # round-robin worker.<zone> intentionally omitted: workers don't
    # serve a single shared protocol the way CPs serve apiserver, and
    # broadcasting every worker IP under one name invites accidental
    # use as if it were a load balancer (that's what prod.<zone> is for).
    {
      for idx, rec in local.worker_indexed_records :
      "${each.value.worker_label}-${idx}" => rec
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
