variable "zone_id" {
  type        = string
  description = "Cloudflare zone ID (32-char hex). Bypasses the zone-name lookup so tokens scoped only to Zone:DNS:Edit work."
}

variable "records" {
  type = map(object({
    ipv4 = list(string)
    ipv6 = list(string)
  }))
  description = <<-EOT
    Map of records keyed by record name (relative or FQDN).
    Each record gets one A per ipv4 entry and one AAAA per ipv6 entry.
    Use a bare label ("cp") for apex-relative records, or a full FQDN
    ("cp-1.antinvestor.com") for explicit names.
  EOT
}

variable "ttl" {
  type        = number
  default     = 60
  description = "DNS TTL in seconds. 1 = 'automatic' (proxied). 60 is the Cloudflare minimum for unproxied records."
}

variable "proxied" {
  type        = bool
  default     = false
  description = "Whether to proxy through Cloudflare. False for cluster endpoints — proxying would break talosctl / kubectl which expect raw TCP on 6443/50000."
}

variable "zone_suffix" {
  type        = string
  description = "The zone's DNS name (e.g. antinvestor.com). Used purely to compose FQDNs for the records output; never sent to the Cloudflare API."
}
