# tofu/layers/03-talos/apply.tf
#
# Uniform per-node Talos config + version reconciliation. Once a node
# is provisioned and reachable on :50000, the apply path is identical
# regardless of provider (Contabo / OCI / on-prem) or role (control-
# plane / worker). The role-vs-provider asymmetry has already been
# resolved upstream:
#
#   - data.talos_machine_configuration.cp[k]      generates CP configs
#   - data.talos_machine_configuration.worker[k]  generates worker configs
#   - local.per_node_configs (per-node-configs-writer.tf) selects the
#     right one for each k.
#
# So this layer's apply path takes the already-customized per-node
# config and pushes it the same way for every node.

locals {
  # Every node we'll dial. Spans CPs + workers, all providers —
  # uniform set. Onprem nodes participate too as long as they have a
  # public ipv4 the runner can reach. No skip list: the apply script
  # handles unreachable nodes (warn-and-continue) and worker errors
  # (warn-and-continue) on its own; only reachable-but-failing CPs
  # fail tofu, which is the correct semantics.
  #
  # null check is necessary because nodes-writer can emit ipv4: null
  # for nodes with no public address (KubeSpan-only onprem). try()
  # alone doesn't coerce null to "" — it only catches lookup errors.
  direct_apply_nodes = {
    for k, v in local.all_nodes_from_state : k => v
    if try(v.ipv4, null) != null && try(v.ipv4, "") != ""
  }

  # CP-only view of the same set — bootstrap + wait_apiserver work on
  # CPs specifically (only CPs run kube-apiserver / etcd).
  direct_controlplane_nodes = {
    for k, v in local.direct_apply_nodes : k => v if try(v.role, "") == "controlplane"
  }

  # Per-CP DNS target. Used by talos_machine_bootstrap and by the
  # apply provisioner — both are mTLS calls and TLS validates the
  # dial target against a SAN. Node IPs are ephemeral (OCI rotates
  # ephemeral public IPv4 on every instance recreate; Contabo public
  # IPs are stable but we don't want to re-issue certs whenever an
  # instance is replaced) so we anchor the dial target to the
  # cp-N.<zone> DNS name, which IS in cert SANs and IS stable across
  # instance churn. cluster_dns republishes the A/AAAA records to the
  # current IPs on every apply.
  cp_apply_target = length(var.cp_dns_zones) > 0 ? {
    for i, k in local.cp_sorted_keys :
    k => "${var.cp_dns_zones[0].cp_label}-${i + 1}.${var.cp_dns_zones[0].zone}"
    } : {
    for k, v in local.controlplane_nodes : k => v.ipv4
  }

  # Per-node dial target. CPs use their cp-N.<zone> DNS name (in cert
  # SANs); workers fall through to ipv4 since there's no per-worker
  # DNS yet. Workers without on-NIC public IPv4 (e.g. an OCI worker)
  # would still hit the SAN problem — but the cluster has none today.
  per_node_apply_target = {
    for k, v in local.direct_apply_nodes : k =>
    try(local.cp_apply_target[k], v.ipv4)
  }

  installer_url    = "factory.talos.dev/installer/${talos_image_factory_schematic.this.id}"
  talosconfig_yaml = data.talos_client_configuration.this.talos_config

  # Staging dir for rendered configs. Outside the tofu tree so init/
  # format don't churn on it. Gitignored.
  apply_stage_dir = "${path.module}/.apply-stage"
}

# Talosconfig is the same for every node — staged once.
resource "local_sensitive_file" "talosconfig" {
  content              = local.talosconfig_yaml
  filename             = "${local.apply_stage_dir}/talosconfig.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

# Each node's already-rendered machine config (CP or worker) staged
# to disk so the provisioner can pass file PATHS rather than the file
# contents (which exceed Linux ARG_MAX as env vars).
resource "local_sensitive_file" "node_machine_config" {
  for_each             = local.direct_apply_nodes
  content              = local.per_node_configs[each.key]
  filename             = "${local.apply_stage_dir}/nodes/${each.key}.yaml"
  file_permission      = "0600"
  directory_permission = "0700"
}

# One uniform apply resource for every node. Triggers on rendered-
# config sha + target version + image_apply_generation + script hash;
# the script itself decides path (insecure apply / config-apply /
# upgrade) based on what the node reports at runtime.
resource "null_resource" "apply_node_config" {
  for_each = local.direct_apply_nodes

  triggers = {
    config_hash    = local_sensitive_file.node_machine_config[each.key].content_sha256
    target_version = var.talos_version
    # Script hash is in the trigger so logic changes (e.g. adding a
    # config-apply step in the running+version-match branch) propagate
    # to nodes whose other triggers are stable. Without this the
    # script edit never fires for steady-state nodes.
    apply_script_hash      = filesha256("${path.module}/../../../scripts/talos-apply-or-upgrade.sh")
    image_apply_generation = each.value.image_apply_generation
  }

  depends_on = [
    local_sensitive_file.node_machine_config,
    local_sensitive_file.talosconfig,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      # Dial target — DNS name for CPs (cert SAN-stable), public IPv4
      # for workers (no per-worker DNS yet). The script uses this for
      # both --endpoints and --nodes; talosctl validates the cert SAN
      # against this value, so it MUST be a name/IP in machine.certSANs.
      NODE_IP   = local.per_node_apply_target[each.key]
      NODE_NAME = each.key
      # The CURRENT public IPv4 from tofu state (post-layer-02-apply,
      # so it reflects an OCI ephemeral-IP rotation in the same apply
      # run). Passed alongside NODE_IP so the script can re-pin
      # /etc/hosts to the live IP — pre-resolve at workflow startup
      # may have pinned the OLD IP before layer 02 recreated the OCI
      # instance, and DNS propagation through 1.1.1.1 lags Cloudflare
      # API by several minutes. NODE_IPV4 is tofu's authoritative view.
      NODE_IPV4 = try(each.value.ipv4, "")
      # Force talosctl's Go runtime to use the libc resolver
      # (getaddrinfo). Pure-Go gRPC's dns resolver bypasses /etc/hosts
      # and queries systemd-resolved (127.0.0.53) directly — so the
      # /etc/hosts pinning we do for the IPv4-only runner has no
      # effect, and talosctl keeps trying the cluster's real public
      # IPv6 (which the runner can't reach) for cp-N.<zone> lookups.
      # cgo's getaddrinfo respects /etc/hosts.
      GODEBUG = "netdns=cgo"
      # Drives the script's failure-isolation policy: workers warn-and-
      # continue, controlplanes fail tofu. Keeps a single worker outage
      # from blocking apply progress on the rest of the cluster.
      NODE_ROLE           = each.value.role
      TARGET_VERSION      = var.talos_version
      INSTALLER_URL       = local.installer_url
      MACHINE_CONFIG_FILE = local_sensitive_file.node_machine_config[each.key].filename
      TALOSCONFIG_FILE    = local_sensitive_file.talosconfig.filename
    }
    command = "${path.module}/../../../scripts/talos-apply-or-upgrade.sh"
  }
}
