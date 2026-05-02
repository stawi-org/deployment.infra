# tofu/layers/03-talos/cluster.tf
#
# Per-node MachineLabels reconciliation against Omni's machine
# inventory. Earlier versions of this layer also drove
# `omnictl apply -f machine-classes.yaml` and `omnictl cluster
# template sync -f main.yaml`, but those are now owned by the
# standalone sync-cluster-template.yml workflow (path-based trigger
# on tofu/shared/clusters/**) — keeping a copy here was duplicative
# and tied cluster-spec lifecycle to node-provisioning applies.
#
# What stays here: per-node label sync. Each upstream node module
# emits `derived_labels` via its `node` output, merged with topology
# / role / provider / account info. We reconcile that desired map
# against Omni's MachineStatus list, matching by hostname → machine
# ID and applying labels via `omnictl machine update`.
#
# Auth + endpoint come from environment:
#   OMNI_SERVICE_ACCOUNT_KEY  — set by the workflow from the repo secret
#   OMNI_ENDPOINT             — defaulted to https://cpd.stawi.org via
#                               var.omni_endpoint, exported below
#
# When omnictl isn't installed (e.g. fresh local clone), the
# null_resource fails with a clear message; the workflow installs
# omnictl as part of layer-03 setup.

# Why a JSON file rather than a per-node null_resource: the matching
# (hostname → machine ID) requires a single `omnictl get machinestatus`
# fetch, and a per-node resource would either pay that cost N times or
# need a shared data-source — clunkier than one batch script.
#
# The labels filter strips:
#   - `node-role.kubernetes.io/*`  (k8s-internal — propagated via Talos
#                                    machine config, not Omni metadata)
#   - any empty-key entries        (defensive)
locals {
  sync_machine_labels_path = "${path.module}/scripts/sync-machine-labels.sh"

  # Per-node labels-and-ip envelope. The script matches Omni Machines
  # by hostname first (works for OCI), then falls back to ipv4 (works
  # for Contabo, where Talos doesn't pick up the friendly platform
  # hostname and falls back to the system UUID).
  omni_machine_apply_per_node = {
    for k, v in local.all_nodes_from_state : k => {
      labels = {
        for lk, lv in try(v.derived_labels, {}) : lk => lv
        if !startswith(lk, "node-role.kubernetes.io/") && lk != ""
      }
      ipv4 = try(v.ipv4, null)
    }
  }
}

resource "local_sensitive_file" "node_labels_json" {
  filename        = "${path.module}/.terraform/node-labels.json"
  content         = jsonencode(local.omni_machine_apply_per_node)
  file_permission = "0600"
}

resource "null_resource" "omnictl_machine_labels" {
  # Triggers on:
  #   labels_sha — re-run when the desired-labels content changes (e.g.
  #                operator adds a label to a node).
  #   nodes_sha  — re-run when ANY upstream node attribute changes
  #                (instance ID, ipv4, etc.). Critical for OCI's
  #                destroy+create flow: the node name is stable but
  #                Omni only sees a fresh Machine after the new
  #                instance phones home, and we need to relabel it
  #                because labels are NOT carried over by Omni
  #                between Machine identities.
  #   script_sha — re-run when the reconciler script changes. Without
  #                this, a script-side bug fix wouldn't get picked up
  #                until something else in the trigger set changed.
  #   endpoint / cluster — invalidate on env target changes.
  triggers = {
    labels_sha = sha256(local_sensitive_file.node_labels_json.content)
    nodes_sha  = sha256(jsonencode(local.all_nodes_from_state))
    script_sha = filesha256(local.sync_machine_labels_path)
    endpoint   = var.omni_endpoint
    cluster    = var.cluster_name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      OMNI_ENDPOINT      = var.omni_endpoint
      OMNI_CLUSTER       = var.cluster_name
      NODE_LABELS_JSON   = local_sensitive_file.node_labels_json.filename
      SYNC_LABELS_SCRIPT = local.sync_machine_labels_path
    }
    command = <<-EOT
      set -euo pipefail
      command -v omnictl >/dev/null || { echo "omnictl not found in PATH; install it first." >&2; exit 1; }
      [[ -n "$${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "OMNI_SERVICE_ACCOUNT_KEY not set in env." >&2; exit 1; }
      bash "$SYNC_LABELS_SCRIPT" "$NODE_LABELS_JSON"
    EOT
  }
}
