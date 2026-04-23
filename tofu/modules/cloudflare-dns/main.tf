# tofu/modules/cloudflare-dns/main.tf
#
# Thin wrapper over cloudflare_dns_record. Takes a zone_id directly (no
# name lookup via data source) so the operator can use a tightly-scoped
# token that only carries Zone:DNS:Edit on the specific zones — no
# Zone:Zone:Read needed.
#
# Each record in var.records produces one A per ipv4 entry and one AAAA
# per ipv6 entry, all sharing the same name (round-robin).

locals {
  # Flatten the (record_name, family, address) triples into a single map
  # keyed by a deterministic stable id so cloudflare_dns_record.for_each works.
  flat = merge([
    for rname, cfg in var.records : merge(
      { for ip in cfg.ipv4 : "${rname}/A/${ip}" => { name = rname, type = "A", content = ip } },
      { for ip in cfg.ipv6 : "${rname}/AAAA/${ip}" => { name = rname, type = "AAAA", content = ip } },
    )
  ]...)
}

resource "cloudflare_dns_record" "this" {
  for_each = local.flat

  zone_id = var.zone_id
  name    = each.value.name
  type    = each.value.type
  content = each.value.content
  ttl     = var.ttl
  proxied = var.proxied
}
