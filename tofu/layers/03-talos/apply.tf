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

  # Per-CP DNS target — used only by talos_machine_bootstrap (mTLS).
  # Bootstrap targets ONE specific CP, and TLS validates that name
  # against a SAN. CPs have cp-N.<zone> records published by
  # cluster_dns; workers don't (yet), so this is sparse.
  cp_apply_target = length(var.cp_dns_zones) > 0 ? {
    for i, k in local.cp_sorted_keys :
    k => "${var.cp_dns_zones[0].cp_label}-${i + 1}.${var.cp_dns_zones[0].zone}"
    } : {
    for k, v in local.controlplane_nodes : k => v.ipv4
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
# config sha + target version + image_apply_generation; the script
# itself decides path (insecure apply / no-op / upgrade) based on
# what the node reports at runtime.
resource "null_resource" "apply_node_config" {
  for_each = local.direct_apply_nodes

  triggers = {
    config_hash            = local_sensitive_file.node_machine_config[each.key].content_sha256
    target_version         = var.talos_version
    image_apply_generation = each.value.image_apply_generation
  }

  depends_on = [
    local_sensitive_file.node_machine_config,
    local_sensitive_file.talosconfig,
  ]

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      NODE_IP   = each.value.ipv4
      NODE_NAME = each.key
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
