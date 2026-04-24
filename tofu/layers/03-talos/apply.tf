# tofu/layers/03-talos/apply.tf

# CP nodes reachable directly from the runner on their public IPv4.
# Oracle CPs are temporarily excluded — the freshly-created OCI instance
# is in state at 141.147.55.5 but :50000 times out from the runner
# (Contabo CPs on the same plan succeed in 1s). Root cause still being
# diagnosed — likely instance-level (user_data not applying, apid not
# binding to the public interface, or OCI routing lag on the ephemeral
# public IP). Un-excluding lets the talos apply hang for 10 min and
# block the whole cluster from ever bootstrapping. Re-enable once we
# can console-log the node and confirm Talos is healthy there.
locals {
  # Nodes we can't currently reach on :50000 from the CI runner — talos
  # applies against them would hang for 10 minutes and block the whole
  # run. Hardcoded here while the underlying nodes are being recovered;
  # promote to a var once we stabilize.
  talos_apply_unreachable = [
    # OCI CP (141.147.55.5) — fresh instance, reachable from OCI but not
    # from GH runner after public IP assignment. Needs node console log
    # to confirm Talos is binding to the public interface.
    "stawi-bwire-oci-stawi-bwire-node-1",
    # Contabo api-3 — connection refused on :50000. Talos not listening.
    # Likely needs ensure_image reinstall; running a reset workflow is
    # the cleanest path.
    "kubernetes-controlplane-api-3",
  ]

  direct_controlplane_nodes = {
    for k, v in local.controlplane_nodes : k => v
    if !contains(local.talos_apply_unreachable, k)
  }
  direct_contabo_worker_nodes = {
    for k, v in local.contabo_worker_nodes : k => v
    if !contains(local.talos_apply_unreachable, k)
  }
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
