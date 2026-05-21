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
# What stays here: per-node Omni Machine label sync, narrowed to
# the two labels Omni-side consumers match on:
#   - node.stawi.org/role — MachineClass routes Machines into
#     the cp / workers MachineSet by selecting on this.
#   - node.stawi.org/name — per-node ConfigPatches
#     (apply-per-node-patches.sh) bind to the matching Machine via
#     target_label_selectors keyed on this.
# The rest of `derived_labels` (provider, account, topology.*) now
# flows to the K8s Node object via Talos `machine.nodeLabels` in
# per-node patches (see tofu/shared/patches/node-{contabo,oracle}.tftpl
# and tofu/layers/03-talos/per-node-patches.tf). This reconciler
# matches nodes to Omni Machines by hostname → machine ID and
# applies the two labels via `omnictl apply` of a MachineLabels
# resource.
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
locals {
  sync_machine_label_path = "${path.module}/scripts/sync-machine-label.sh"

  # Per-node labels-and-ip envelope.
  #
  # Narrowed 2026-05-05 to the two labels Omni-side consumers
  # actually match on:
  #   - node.stawi.org/role  — MachineClass selectors in
  #     tofu/shared/clusters/machine-classes.yaml route the Machine
  #     into the cp / workers MachineSet.
  #   - node.stawi.org/name  — per-node ConfigPatches
  #     (apply-per-node-patches.sh, T10) bind to the matching
  #     Machine via target_label_selectors keyed on this.
  #
  # Other labels — provider, account, topology.kubernetes.io/* —
  # moved to Talos `machine.nodeLabels` via per-node patches in
  # tofu/shared/patches/node-{contabo,oracle}.tftpl. K8s Node
  # labels live on the K8s API; Omni Machine labels live on Omni's
  # inventory; previously these were conflated and synced together
  # to Omni only, leaving K8s Node labels orphaned.
  #
  # Path to dropping this sync entirely is the kernel-cmdline
  # initial-labels TODO in tofu/shared/clusters/main.yaml — once
  # both labels can be baked into kernel cmdline at image-mint
  # time, MachineClass selectors fire and per-node ConfigPatches
  # bind without any post-registration sync, and this whole
  # reconciler retires.
  omni_machine_apply_per_node = {
    for k, v in local.all_nodes_from_state : k => {
      labels = {
        for lk, lv in {
          "node.stawi.org/role" = try(v.derived_labels["node.stawi.org/role"], "")
          "node.stawi.org/name" = try(v.derived_labels["node.stawi.org/name"], k)
        } : lk => lv
        if lv != ""
      }
      ipv4 = try(v.ipv4, null)
    }
  }
}

# Per-machine MachineLabels sync — one null_resource instance per node
# in inventory. The singleton form this replaced (re-keyed on the sha
# of the full nodes map) re-ran the reconciler against EVERY machine
# whenever ANY node attribute moved; that turned a single-account
# onboarding into a fleet-wide 15-minute polling loop.
#
# Per-instance triggers carry only that node's label content + ipv4,
# plus shared env-target shas. Adding a node creates one new instance;
# changing one node's role re-keys exactly one instance. Bug-fixing
# the script (script_sha) or rerouting Omni (endpoint/cluster) still
# fans out — those are semantics-changing events that genuinely need
# a fleet-wide replay.
#
# label_sync_retry_token (var) is the operator escape hatch for the
# polling-timeout case: a machine that wasn't yet registered when its
# instance first applied has the resource marked created with a WARN,
# and re-applying with the same inputs is a no-op. Bumping the token
# re-keys every instance and forces a fresh attempt.
resource "null_resource" "omnictl_machine_label" {
  for_each = local.omni_machine_apply_per_node

  triggers = {
    labels_sha  = sha256(jsonencode(each.value.labels))
    ipv4        = try(each.value.ipv4, "")
    script_sha  = filesha256(local.sync_machine_label_path)
    endpoint    = var.omni_endpoint
    cluster     = var.cluster_name
    retry_token = var.label_sync_retry_token
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      OMNI_ENDPOINT     = var.omni_endpoint
      OMNI_CLUSTER      = var.cluster_name
      NODE_NAME         = each.key
      NODE_LABELS_JSON  = jsonencode(each.value.labels)
      NODE_IPV4         = try(each.value.ipv4, "")
      SYNC_LABEL_SCRIPT = local.sync_machine_label_path
    }
    command = <<-EOT
      set -euo pipefail
      command -v omnictl >/dev/null || { echo "omnictl not found in PATH; install it first." >&2; exit 1; }
      [[ -n "$${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "OMNI_SERVICE_ACCOUNT_KEY not set in env." >&2; exit 1; }
      bash "$SYNC_LABEL_SCRIPT"
    EOT
  }
}
