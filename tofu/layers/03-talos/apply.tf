# tofu/layers/03-talos/apply.tf

# CP nodes reachable directly from the runner on their public IPv4.
# Every provider we currently support (Contabo, OCI since the VCN
# switched to a public subnet, on-prem when joining via KubeSpan + a
# reachable endpoint) exposes the Talos API at ipv4:50000, so no
# provider-specific filter is needed anymore. Keep the separate
# "direct" name so a future private-only provider can be excluded
# without renaming callers.
locals {
  direct_controlplane_nodes = local.controlplane_nodes
}

# terraform_data tracks the rendered machine config content per node. When the
# config changes (version bump, patch edit, label change, etc.), its output
# changes and `replace_triggered_by` below forces the apply resource to be
# replaced, i.e. a full re-apply with apply_mode=reboot.
resource "terraform_data" "cp_config_hash" {
  for_each = local.direct_controlplane_nodes
  input = {
    config     = data.talos_machine_configuration.cp[each.key].machine_configuration
    generation = var.force_talos_reapply_generation
    # Bumps whenever the underlying node module reinstalls (Contabo:
    # null_resource.ensure_image runs; Oracle: instance is replaced).
    # Forces talos_machine_configuration_apply.cp to re-run against
    # the freshly-wiped disk — without this, tofu thinks the config is
    # still applied and downstream layers get a node with correct
    # state metadata but an empty / unconfigured OS.
    image_apply_generation = each.value.image_apply_generation
  }
}

resource "talos_machine_configuration_apply" "cp" {
  for_each                    = local.direct_controlplane_nodes
  client_configuration        = data.terraform_remote_state.secrets.outputs.client_configuration
  machine_configuration_input = data.talos_machine_configuration.cp[each.key].machine_configuration
  node                        = each.value.ipv4
  endpoint                    = each.value.ipv4
  # apply_mode = "reboot" forces the node to reboot after each config change so
  # kubelet + other services restart cleanly with the new version. Without this,
  # Talos stages the config and services keep running on the old one until the
  # next manual reboot — which masquerades as "healthy config applied" in tofu
  # state but leaves broken kubelet image pulls stuck.
  apply_mode = "reboot"

  depends_on = [null_resource.talos_upgrade]

  lifecycle {
    replace_triggered_by = [terraform_data.cp_config_hash[each.key]]
  }
}
