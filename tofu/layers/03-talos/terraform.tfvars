# tofu/layers/03-talos/terraform.tfvars
#
# Layer-03 drives Omni cluster-template sync, per-machine label
# assignment via omnictl, and cross-provider cluster DNS (cp-N +
# prod.<zone>). Its only required vars are the SOPS health-check
# fixture's age recipient and the Cloudflare zones to publish into.

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Cloudflare zones for cluster DNS. zone_id values come from the
# Cloudflare dashboard (zone "Overview" page) — not from the API, so a
# token scoped only to Zone:DNS:Edit works.
#
# For each zone this layer publishes:
#   cp-<N>.<zone>     — per-CP A/AAAA, 1-indexed by sorted node key
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
