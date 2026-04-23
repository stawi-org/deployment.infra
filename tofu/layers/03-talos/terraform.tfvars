# tofu/layers/03-talos/terraform.tfvars
#
# cluster_endpoint is the Talos/Kubernetes API endpoint embedded in every
# machine config generated in this layer. kubernetes-controlplane-api-1's
# public IPv4 on Contabo is preserved across reinstalls, so it's stable.
cluster_endpoint = "https://cp.antinvestor.com:6443"

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
