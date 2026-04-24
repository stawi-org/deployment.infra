# tofu/layers/03-talos/terraform.tfvars
#
# cluster_endpoint is the Talos/Kubernetes API endpoint embedded in every
# machine config generated in this layer. kubernetes-controlplane-api-1's
# public IPv4 on Contabo is preserved across reinstalls, so it's stable.
cluster_endpoint = "https://cp.antinvestor.com:6443"

age_recipients = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"

# Bump this to force all talos_machine_configuration_apply resources to be
# replaced (destroy + recreate) on the next apply. Used for recovery when
# nodes are stuck in a bad state — e.g. kubelet ImagePullBackOff from a
# previously-staged config that never got rebooted. Combined with
# apply_mode = "reboot", the replacement triggers a fresh config push and
# node reboot, unblocking image pulls.
#
# Bump history:
#   1 -> 2 (#17): introduced; no-op (terraform_data new).
#   2 -> 3 (#18): would have triggered replace_triggered_by but apply errored before
#                 state persisted the new resources, so plan still showed "create".
#   3 -> 4 (this): pairs with new null_resource.reboot_cp — the generation trigger
#                  forces an explicit `talosctl reboot --wait` per CP node, which
#                  bypasses the Talos-provider-doesn't-reboot-on-config-change
#                  issue entirely. This is the deterministic fix.
force_talos_reapply_generation = "4"

# Cloudflare zones for cluster DNS. zone_id values come from the
# Cloudflare dashboard (zone "Overview" page) — not from the API, so a
# token scoped only to Zone:DNS:Edit works.
#
# For each zone this layer publishes:
#   cp.<zone>         — round-robin A/AAAA across every controlplane node
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

# Nodes currently unreachable on :50000 from CI. Apply passes skip
# them so a run can complete in under 10 min. Remove an entry once the
# node is recovered (node-recovery workflow handles reinstall/reboot).
talos_apply_skip = [
  "oci-stawi-bwire-node-1",        # OCI CP — needs console-log diagnosis
  "kubernetes-controlplane-api-3", # Contabo worker — Talos not listening
  "kubernetes-controlplane-api-2", # Contabo CP — etcd never joined after reinstall
]
