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

  # Per-CP apply target. Each CP gets cp-<N>.<first-zone> where N is
  # its 1-based index in cp_sorted_keys; that DNS resolves to the
  # node's public IP (Cloudflare A/AAAA managed by cluster_dns) and
  # is in cp_cert_sans, so TLS validates regardless of provider.
  # Falls back to per-node IP when no DNS zone is configured (local
  # dev). ApplyConfiguration is a per-node RPC — Talos doesn't proxy
  # it — so we MUST dial each node specifically; round-robin DNS
  # would land all CPs on whichever single backend resolved.
  cp_apply_target = length(var.cp_dns_zones) > 0 ? {
    for i, k in local.cp_sorted_keys :
    k => "${var.cp_dns_zones[0].cp_label}-${i + 1}.${var.cp_dns_zones[0].zone}"
    } : {
    for k, v in local.controlplane_nodes : k => v.ipv4
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
  # Per-CP DNS target — each CP's own cp-<N>.<zone>. ApplyConfiguration
  # is non-proxying so this MUST resolve to the specific node we're
  # configuring. cert SANs include the same name, so TLS validates.
  node     = local.cp_apply_target[each.key]
  endpoint = local.cp_apply_target[each.key]
  # apply_mode = "auto" lets Talos decide whether the change requires a
  # reboot. Most diffs (cert SANs, node labels, sysctls, kubelet args)
  # are applied live and never touch services. The previous "reboot"
  # default fired all 3 CPs simultaneously on every config change,
  # which broke etcd quorum during a normal apply (every CP gone at
  # once for 60-180s) and made wait_apiserver hit its timeout.
  apply_mode = "auto"


  lifecycle {
    replace_triggered_by = [terraform_data.cp_config_hash[each.key]]
  }
}
