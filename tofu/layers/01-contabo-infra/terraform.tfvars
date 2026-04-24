# tofu/layers/01-contabo-infra/terraform.tfvars
# Inventory is injected from the canonical R2 object at production/config/cluster-inventory.yaml.
contabo_accounts = {}

# ssh_public_key is injected via env var TF_VAR_ssh_public_key (from GitHub secrets or operator env).


# Cluster DNS (cp.* + cp-<N>.* round-robin + prod.* for LB-labelled
# nodes) is published by layer 03-talos, which has a global view of
# every CP across every provider. Zone configuration lives in that
# layer's terraform.tfvars — not here.

# Bump to force a disk-wipe reinstall of ALL 3 Contabo CPs on the
# next apply. Set to 1 once after the 2026-04-22 cascade incident
# broke etcd on the live cluster; reset-cluster wiped state, and
# this forces ensure-image.sh to actually re-image the disks from
# v1.13.0-alpha.2 (current) to v1.12.6 (configured target).
#
# Do NOT bump for routine Talos version changes — those flow through
# the (pending) in-place talosctl upgrade path. Bumping this wipes
# etcd and workloads on the Contabo CPs.
force_reinstall_generation = 7

# Per-node surgical reinstall. Add/bump an entry to wipe and re-flash
# a single Contabo node without touching the others (the cluster-wide
# variable above wipes every CP in parallel, which takes etcd below
# quorum if any CP was healthy).
#
# Example:
#   per_node_force_reinstall_generation = {
#     "contabo-stawi-contabo-node-3" = 1  # first wipe of api-3
#   }
# Bump to 2, 3, … on each subsequent reinstall of the same node.
per_node_force_reinstall_generation = {}

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"
