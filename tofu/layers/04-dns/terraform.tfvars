# tofu/layers/04-dns/terraform.tfvars
#
# DNS-only layer (carved out of 03-talos in 2026-05). Publishes cluster
# DNS records to Cloudflare independent of Talos machine-config apply,
# so CF API failures don't block infrastructure setup.

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Cloudflare zones for cluster DNS. zone_id values come from the
# Cloudflare dashboard (zone "Overview" page) — not from the API, so a
# token scoped only to Zone:DNS:Edit works.
#
# For each zone this layer publishes:
#   prod.<zone>       — round-robin across nodes carrying
#                       node.kubernetes.io/external-load-balancer="true"
#                       (omitted if no such nodes exist)
cp_dns_zones = [
  {
    zone    = "antinvestor.com"
    zone_id = "e5a43681579acad9c15657ac21dbd66a"
  },
  {
    zone    = "stawi.org"
    zone_id = "706bf604a333d866bb38c03bf643e79a"
  },
]
