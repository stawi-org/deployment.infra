# tofu/layers/01-contabo-infra/terraform.tfvars
# Legacy fallback inventory for local use. Production should prefer the
# canonical R2 inventory object at production/config/cluster-inventory.yaml.
controlplane_nodes = {
  "kubernetes-controlplane-api-1" = { product_id = "V94", region = "EU" }
  "kubernetes-controlplane-api-2" = { product_id = "V94", region = "EU" }
  "kubernetes-controlplane-api-3" = { product_id = "V94", region = "EU" }
}

# ssh_public_key is injected via env var TF_VAR_ssh_public_key (from GitHub secrets or operator env);
# contabo_* variables are injected via env vars TF_VAR_contabo_client_id etc.


# Cloudflare zones for CP DNS. zone_id values come from the Cloudflare
# dashboard (zone "Overview" page) — not from the API, so a token
# scoped to only Zone:DNS:Edit works.
#
# MAP THE TWO IDs BEFORE FIRST APPLY. The token provided to this repo
# was created with DNS:Edit on two zone resources:
#   e5a43681579acad9c15657ac21dbd66a
#   706bf604a333d866bb38c03bf643e79a
# Log into Cloudflare and confirm which ID belongs to which domain;
# swap the assignments below if the guess is wrong.
cp_dns_zones = [
  {
    zone    = "antinvestor.com"
    zone_id = "e5a43681579acad9c15657ac21dbd66a"
    label   = "cp"
    indexed = true
  },
  {
    zone    = "stawi.org"
    zone_id = "706bf604a333d866bb38c03bf643e79a"
    label   = "cp"
    indexed = false
  },
]

# Bump to force a disk-wipe reinstall of ALL 3 Contabo CPs on the
# next apply. Set to 1 once after the 2026-04-22 cascade incident
# broke etcd on the live cluster; reset-cluster wiped state, and
# this forces ensure-image.sh to actually re-image the disks from
# v1.13.0-alpha.2 (current) to v1.12.6 (configured target).
#
# Do NOT bump for routine Talos version changes — those flow through
# the (pending) in-place talosctl upgrade path. Bumping this wipes
# etcd and workloads on the Contabo CPs.
force_reinstall_generation = 6
