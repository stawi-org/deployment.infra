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
}

# Records map per zone, lifted to a root-level local so the import
# block below can derive flat-keys from the same source without
# routing through module.cluster_dns outputs (any reference to module
# outputs from an import block targeting that same module's resources
# produces a tofu cycle: module → outputs → root local → import →
# module's resource → module-close).
locals {
  # Note: the bare `cp.<zone>` round-robin (used to be A/AAAA across
  # every CP node so kubectl could dial the cluster directly) is now
  # owned exclusively by the 00-omni-server layer, which points it at
  # the Omni dashboard host (orange-cloud). Cluster access is mediated
  # by Omni; direct-to-CP DNS would shadow the Omni record because CF
  # returns BOTH proxied + DNS-only A records to clients (browser
  # round-robins, lands on a Talos node IP, gets refused). Per-CP
  # records (cp-1, cp-2, …) and the prod LB record are still useful for
  # break-glass operations, so they stay.
  #
  # The cp-<N>.<zone> records are also load-bearing for `apply.tf`'s
  # cp_apply_target — talos_machine_configuration_apply and
  # talos_machine_bootstrap dial each CP at `cp-N.<zone>:50000` over
  # mTLS, and the Talos cluster cert pins those hostnames as SANs.
  # Raw IPs aren't in SANs because OCI ephemeral IPv4 churns on every
  # instance recreate. Removing cp-N would break every Talos apply
  # until apply.tf is rewired to push machine configs through Omni's
  # machine-api instead.
  cluster_dns_records_per_zone = {
    for z in var.cp_dns_zones : z.zone => merge(
      # cp-<N>.<zone> — per-CP (talosctl-by-node, also load-bearing
      # for apply.tf's cp_apply_target hostname-pinned mTLS dial).
      {
        for idx, rec in local.cp_indexed_records :
        "${z.cp_label}-${idx}" => rec
      },
      # prod.<zone> — round-robin across LB-labelled nodes (if any)
      local.lb_has_any ? {
        (z.prod_label) = {
          ipv4 = local.lb_all_ipv4
          ipv6 = local.lb_all_ipv6
        }
      } : {},
    )
  }
}

module "cluster_dns" {
  for_each = { for z in var.cp_dns_zones : z.zone => z }

  source      = "../../modules/cloudflare-dns"
  zone_id     = each.value.zone_id
  zone_suffix = each.value.zone
  records     = local.cluster_dns_records_per_zone[each.value.zone]

  proxied = false # Raw TCP required for talosctl (50000) and apiserver (6443).
  ttl     = 60    # Short so node replacements propagate quickly.
}

# ---------------------------------------------------------------------
# Cloudflare drift adoption.
# ---------------------------------------------------------------------
# When a record already exists in Cloudflare but isn't in tofu state
# (e.g. partial-apply failure, state-clear, operator-created record
# that happens to match what the module wants to manage), tofu's
# create attempt POSTs an identical record and CF returns 400
# "An identical record already exists". The two stawi.org prod/AAAA
# records that surfaced this whole class of failure motivated the
# self-heal below.
#
# Both the data source and the import block live at the root because:
#   - import blocks aren't allowed in child modules.
#   - The data source can't live in the child module either: its
#     output flowing into a root-level import that targets the
#     module's own resource produces a tofu cycle
#     (module.cluster_dns ↔ module.cluster_dns (close)).
# Putting both at root breaks the cycle: the data source has no
# dependency on the module's resources, and the import block reads
# only root-locals + module outputs (flat_keys, zone_id) that don't
# transit the resource.
data "cloudflare_dns_records" "existing_per_zone" {
  for_each = { for z in var.cp_dns_zones : z.zone_id => z }
  zone_id  = each.key
}

locals {
  # Fast index of cp_dns_zones by zone_id.
  zones_by_id = { for z in var.cp_dns_zones : z.zone_id => z }

  # Intended records expanded into one record per (zone, name, type,
  # content) tuple, with both the resource flat_key (used to address
  # the resource — must match the module's local.flat keying exactly)
  # AND a canonical_key (IPv6 normalised via cidrhost) for matching
  # against CF's as-returned content. AAAA content drift between tofu
  # state (expanded "2a02:c207:2272:7782:0000:0000:0000:0001") and
  # CF storage (compressed "2a02:c207:2272:7782::1") makes flat-key
  # equality alone unreliable; canonicalising both sides via cidrhost
  # gives the lookup a stable spelling.
  cluster_dns_intended_records = merge([
    for zone, recs in local.cluster_dns_records_per_zone : {
      for entry in flatten([
        for rname, cfg in recs : concat(
          [for ip in cfg.ipv4 : {
            zone          = zone
            flat_key      = "${rname}/A/${ip}"
            canonical_key = "${rname}/A/${ip}"
          }],
          [for ip in cfg.ipv6 : {
            zone          = zone
            flat_key      = "${rname}/AAAA/${ip}"
            canonical_key = "${rname}/AAAA/${cidrhost("${ip}/128", 0)}"
          }],
        )
      ]) : "${entry.zone}::${entry.flat_key}" => entry
    }
  ]...)

  # Existing CF records indexed by canonical key. cidrhost is a no-op
  # for IPv4 and yields the canonical compressed form for IPv6, which
  # matches the canonical_key shape above. On any data-source error
  # try() coerces the failure to an empty list — to_import becomes {}
  # and the import block is a no-op.
  existing_records_by_zone_canonical_key = merge([
    for zone_id, dns in data.cloudflare_dns_records.existing_per_zone : {
      for r in try(dns.result, []) :
      "${local.zones_by_id[zone_id].zone}::${trimsuffix(r.name, ".${local.zones_by_id[zone_id].zone}")}/${r.type}/${r.type == "AAAA" ? cidrhost("${r.content}/128", 0) : r.content}" => r.id
    }
  ]...)

  # Final import set: every intended record whose canonical key has a
  # match in CF, addressed back through the resource's flat_key.
  cluster_dns_to_import = {
    for k, v in local.cluster_dns_intended_records :
    k => {
      zone      = v.zone
      flat_key  = v.flat_key
      record_id = local.existing_records_by_zone_canonical_key["${v.zone}::${v.canonical_key}"]
    }
    if contains(keys(local.existing_records_by_zone_canonical_key), "${v.zone}::${v.canonical_key}")
  }
}

import {
  for_each = local.cluster_dns_to_import
  to       = module.cluster_dns[each.value.zone].cloudflare_dns_record.this[each.value.flat_key]
  # Cloudflare resource-import id format: "<zone_id>/<record_id>".
  # zone_id sourced directly from var (NOT from module output) to keep
  # the import block out of the module-close cycle.
  id = "${local.zones_by_id_to_zone_id[each.value.zone]}/${each.value.record_id}"
}

locals {
  # Reverse index: zone_suffix → zone_id, used by the import block's
  # `id` so we don't reference module outputs.
  zones_by_id_to_zone_id = { for z in var.cp_dns_zones : z.zone => z.zone_id }
}

# Diagnostic outputs surfaced as `tofu output` for debugging the
# import-block lookup when CF returns an "identical record already
# exists" error despite the self-heal being in place. Lists the
# computed intended-canonical-keys, the existing CF-canonical-keys,
# and the intersection. Mismatches here pinpoint whether the data
# source missed records (nothing in existing) or the canonical-form
# computation differs across sides (entries in both but no overlap).
output "_debug_dns_intended_canonical_keys" {
  description = "Intended cloudflare records keyed by canonical lookup form. Should match the keys in _debug_dns_existing_canonical_keys for any record that already exists in CF."
  value       = { for k, v in local.cluster_dns_intended_records : k => "${v.zone}::${v.canonical_key}" }
}

output "_debug_dns_existing_canonical_keys" {
  description = "Existing CF records keyed by canonical lookup form. If empty, the cloudflare_dns_records data source returned nothing (auth scope / pagination / API issue) and the self-heal can't run."
  value       = local.existing_records_by_zone_canonical_key
}

output "_debug_dns_to_import" {
  description = "Resolved import set. Empty when no overlap was found between intended and existing — but a CF 'identical record exists' error proves overlap actually exists, indicating a canonical-key normalization bug."
  value       = local.cluster_dns_to_import
}
