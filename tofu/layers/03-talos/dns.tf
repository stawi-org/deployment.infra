# tofu/layers/03-talos/dns.tf
#
# Cross-provider cluster DNS — publishes the public-load-balancer
# round-robin only.
#
#   prod.<zone>      A/AAAA across every node carrying
#                    `node.kubernetes.io/external-load-balancer="true"`.
#                    Frontends ingress traffic into the cluster. The
#                    LB itself terminates TLS via cert-manager inside
#                    the cluster, so this record is plain DNS-only.
#
# Per-CP `cp-<N>.<zone>` records used to live here for talosctl-by-
# node mTLS dialing. They were dropped in 2026-04 along with the rest
# of the talosctl-bootstrap path — the cluster's k8s API is now
# reached via Omni's k8s-proxy at `cp.<zone>` (owned by the
# 00-omni-server layer, orange-cloud), and Talos node access is via
# Omni's machine-api passthrough. Tofu has no per-CP record need.
#
# Runs in layer 03 because that's the first layer with a global view
# of every node (layer 01 sees only Contabo; layer 02 sees only one
# cloud at a time). LB nodes can come from any provider.

locals {
  # Filter by the external-load-balancer label regardless of role. A
  # CP and a worker can both be LB-ingress entrypoints; any node with
  # the label participates in prod.<zone>. The label key matches
  # what kube-proxy / cloud-controller-managers expect on a node so
  # the same label can drive in-cluster service-IP allocation later.
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
}

# Records map per zone, lifted to a root-level local so the import
# block below can derive flat-keys without routing through
# module.cluster_dns outputs (any reference to module outputs from an
# import block targeting that same module's resources produces a tofu
# cycle: module → outputs → root local → import → module's resource →
# module-close).
locals {
  cluster_dns_records_per_zone = {
    for z in var.cp_dns_zones : z.zone => (
      local.lb_has_any ? {
        (z.prod_label) = {
          ipv4 = local.lb_all_ipv4
          ipv6 = local.lb_all_ipv6
        }
      } : {}
    )
  }
}

module "cluster_dns" {
  for_each = { for z in var.cp_dns_zones : z.zone => z }

  source      = "../../modules/cloudflare-dns"
  zone_id     = each.value.zone_id
  zone_suffix = each.value.zone
  records     = local.cluster_dns_records_per_zone[each.value.zone]

  proxied = false # Plain DNS-only — LB nodes terminate TLS in-cluster.
  ttl     = 60    # Short so node replacements propagate quickly.
}

# ---------------------------------------------------------------------
# Cloudflare drift adoption.
# ---------------------------------------------------------------------
# When a record already exists in Cloudflare but isn't in tofu state
# (e.g. partial-apply failure, state-clear, operator-created record
# that happens to match what the module wants to manage), tofu's
# create attempt POSTs an identical record and CF returns 400
# "An identical record already exists". The self-heal below queries
# CF for existing records and imports them.
#
# Both the data source and the import block live at the root because:
#   - import blocks aren't allowed in child modules.
#   - The data source can't live in the child module either: its
#     output flowing into a root-level import that targets the
#     module's own resource produces a tofu cycle
#     (module.cluster_dns ↔ module.cluster_dns (close)).
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
  # state (expanded form) and CF storage (compressed form) makes flat-
  # key equality alone unreliable; canonicalising via cidrhost gives
  # the lookup a stable spelling.
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

  # Reverse index: zone_suffix → zone_id, used by the import block's
  # `id` so we don't reference module outputs.
  zones_by_id_to_zone_id = { for z in var.cp_dns_zones : z.zone => z.zone_id }
}

import {
  for_each = local.cluster_dns_to_import
  to       = module.cluster_dns[each.value.zone].cloudflare_dns_record.this[each.value.flat_key]
  # Cloudflare resource-import id format: "<zone_id>/<record_id>".
  id = "${local.zones_by_id_to_zone_id[each.value.zone]}/${each.value.record_id}"
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
