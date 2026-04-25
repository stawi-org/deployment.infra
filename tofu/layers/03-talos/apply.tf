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
  # Nodes that are declared in inventory but currently unreachable on
  # :50000 from CI. Driven by var.talos_apply_skip so operators can
  # toggle a node's healthy/unreachable status without a code change.
  # Entries here remain in controlplane_nodes / worker_nodes / DNS /
  # cert SANs — they just don't receive talosctl apply passes.

  direct_controlplane_nodes = {
    for k, v in local.controlplane_nodes : k => v
    if !contains(var.talos_apply_skip, k)
  }
  direct_contabo_worker_nodes = {
    for k, v in local.contabo_worker_nodes : k => v
    if !contains(var.talos_apply_skip, k)
  }

  # DNS-name endpoint for CPs whose public IPv4 isn't on-NIC
  # (currently OCI). Their auto-generated cert won't include the
  # public IP, so we connect via cp-<N>.<zone> and rely on
  # extra_cert_sans in user_data to make SNI match a SAN. Contabo
  # nodes keep IP-based endpoints — their public IPv4 IS the NIC
  # address, Talos auto-discovers it into the cert, and IP works
  # without depending on the runner's DNS resolver (which has been
  # unreliable when querying through systemd-resolved).
  cp_endpoint_dns = length(var.cp_dns_zones) > 0 ? {
    for i, k in local.cp_sorted_keys :
    k => "${var.cp_dns_zones[0].cp_label}-${i + 1}.${var.cp_dns_zones[0].zone}"
    if try(local.controlplane_nodes[k].provider, "") == "oracle"
  } : {}
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
  # Both `node` and `endpoint` set to a DNS name when one's available so
  # gRPC's TLS handshake uses the DNS name for SNI / cert verification.
  # OCI public IPv4s are NAT'd (not on-NIC), so Talos won't auto-include
  # them in its serving cert; the node's user_data has cp-N.<zone> in
  # machine.certSANs (modules/oracle-account-infra/variables.tf::
  # extra_cert_sans), and matching the connection target to that SAN
  # is the only way to pass verification.
  node     = try(local.cp_endpoint_dns[each.key], each.value.ipv4)
  endpoint = try(local.cp_endpoint_dns[each.key], each.value.ipv4)
  # apply_mode = "reboot" forces the node to reboot after each config change so
  # kubelet + other services restart cleanly with the new version. Without this,
  # Talos stages the config and services keep running on the old one until the
  # next manual reboot — which masquerades as "healthy config applied" in tofu
  # state but leaves broken kubelet image pulls stuck.
  apply_mode = "reboot"


  lifecycle {
    replace_triggered_by = [terraform_data.cp_config_hash[each.key]]
  }
}
