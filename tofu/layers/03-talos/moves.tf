# tofu/layers/03-talos/moves.tf
#
# State migrations for the layer-03 apply path.
#
# Generation history:
#   1. talos_machine_configuration_apply.{cp,worker_contabo}
#      + terraform_data.{cp,worker_contabo}_config_hash
#      The original mTLS apply via the talos provider. Removed when we
#      moved to talosctl --insecure shelling out from null_resource.
#
#   2. null_resource.{apply_cp_config, apply_worker_contabo_config}
#      + local_sensitive_file.{cp,worker}_machine_config
#      Provider-aware split: separate resources for CPs vs Contabo
#      workers. Removed in favour of one uniform per-node apply.
#
#   3. null_resource.apply_node_config
#      + local_sensitive_file.node_machine_config
#      Current. Single resource for every node — CP or worker, Contabo
#      or OCI or onprem — keyed by node name.

# ---- Generation 1 → 2 (state cleanup) ----------------------------
removed {
  from = talos_machine_configuration_apply.cp
  lifecycle { destroy = false }
}
removed {
  from = talos_machine_configuration_apply.worker_contabo
  lifecycle { destroy = false }
}
removed {
  from = terraform_data.cp_config_hash
  lifecycle { destroy = false }
}
removed {
  from = terraform_data.worker_contabo_config_hash
  lifecycle { destroy = false }
}

# ---- Generation 2 → 3 (rename + merge) ---------------------------
moved {
  from = null_resource.apply_cp_config
  to   = null_resource.apply_node_config
}
moved {
  from = null_resource.apply_worker_contabo_config
  to   = null_resource.apply_node_config
}
moved {
  from = local_sensitive_file.cp_machine_config
  to   = local_sensitive_file.node_machine_config
}
moved {
  from = local_sensitive_file.worker_machine_config
  to   = local_sensitive_file.node_machine_config
}
