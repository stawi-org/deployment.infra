# tofu/layers/03-talos/moves.tf
#
# State migrations for the layer-03 apply path.
#
# Generation history:
#   1. talos_machine_configuration_apply.{cp,worker_contabo}
#      + terraform_data.{cp,worker_contabo}_config_hash
#      Original mTLS apply via the talos provider. Retired when we
#      switched to talosctl --insecure shelling out from null_resource.
#   2. null_resource.{apply_cp_config, apply_worker_contabo_config}
#      + local_sensitive_file.{cp,worker}_machine_config
#      Provider-aware split. Retired in favour of a unified per-node
#      apply.
#   3. null_resource.apply_node_config + local_sensitive_file.node_machine_config
#      Single resource for every node, keyed by node name.
#   4. (2026-04-30) Talos-bootstrap path retired entirely. Layer 03 is
#      now Omni-driven (omnictl cluster template sync + per-machine
#      label sync) — the talos provider, talosctl shell-outs, and
#      machine-config artifacts are all gone. moves.tf cleans them out
#      of state.
#
# Destroy callbacks for the resources below are no-ops in real terms —
# talos_cluster_kubeconfig is a fetch wrapper, the null_resources have
# empty triggers, local_sensitive_file just unlinks an ephemeral file
# in the runner's workspace, and aws_s3_object on R2 was already kept
# orphaned by earlier rotations. lifecycle.destroy = false keeps the
# state mutation purely state-only either way.

# ---- 2026-04 retirement: Talos bootstrap path → Omni ---------------
removed {
  from = talos_machine_secrets.this
  lifecycle { destroy = false }
}
removed {
  from = talos_cluster_kubeconfig.this
  lifecycle { destroy = false }
}
removed {
  from = null_resource.apply_node_config
  lifecycle { destroy = false }
}
removed {
  from = null_resource.bootstrap
  lifecycle { destroy = false }
}
removed {
  from = null_resource.wait_apiserver
  lifecycle { destroy = false }
}
removed {
  from = null_resource.reboot_cp
  lifecycle { destroy = false }
}
removed {
  from = local_sensitive_file.node_machine_config
  lifecycle { destroy = false }
}
removed {
  from = local_sensitive_file.machine_configs_yaml_sopsed
  lifecycle { destroy = false }
}
removed {
  from = aws_s3_object.machine_configs_yaml
  lifecycle { destroy = false }
}
removed {
  from = terraform_data.config_hash
  lifecycle { destroy = false }
}
removed {
  from = terraform_data.bootstrap_hash
  lifecycle { destroy = false }
}

# ---- Generation 1 → 2 (legacy state cleanup) ----------------------
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

# ---- Generation 2 → 3 (legacy rename) -----------------------------
# Earlier renames are now subsumed by the Generation-4 retirement
# (apply_node_config / node_machine_config no longer exist), but
# keeping the removed{} blocks here makes a fresh-clone init from
# old state idempotent.
removed {
  from = null_resource.apply_cp_config
  lifecycle { destroy = false }
}
removed {
  from = null_resource.apply_worker_contabo_config
  lifecycle { destroy = false }
}
removed {
  from = local_sensitive_file.cp_machine_config
  lifecycle { destroy = false }
}
removed {
  from = local_sensitive_file.worker_machine_config
  lifecycle { destroy = false }
}
