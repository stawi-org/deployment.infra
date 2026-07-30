# tofu/modules/gcp-account-infra/defaults.tf
#
# Desired-state defaults live here — not in Python seed scripts.
# Empty R2 inventory (or nodes: {}) → two Spot workers, unless
# account annotations disable workers (see workers_enabled below).
# Operators override by writing a non-empty nodes map to R2; the
# next apply uses that map as-is and the nodes-writer persists it.
#
# Omni host may share the same GCP project (00-omni-server); that is
# independent of this worker pack. Disable workers without removing
# the account from accounts.yaml:
#   annotations:
#     node.stawi.org/workers-enabled: "false"
#   nodes: {}

locals {
  # e2-standard-2 = 2 vCPU / 8 GiB (e2-medium is only 4 GiB).
  default_machine_type = "e2-standard-2"
  default_boot_disk_gb = 50
  default_node_count   = 2
  default_zone         = "${var.region}-b"

  # Explicit opt-out so empty nodes:{} does not re-seed the default
  # Spot pack (used when the cluster is OCI-only but the project still
  # hosts omni-host / WIF).
  workers_enabled = lower(trimspace(try(
    var.annotations["node.stawi.org/workers-enabled"],
    "true",
  ))) != "false"

  default_nodes = {
    for i in range(1, local.default_node_count + 1) :
    "gcp-${var.account_key}-node-${i}" => {
      role         = "worker"
      machine_type = local.default_machine_type
      zone         = local.default_zone
      boot_disk_gb = local.default_boot_disk_gb
      preemptible  = true
      labels = {
        "node.stawi.org/plane"          = "worker"
        "node.stawi.org/capacity-class" = "spot"
        # CNPG requires role-database=true; keep false on Spot workers.
        "node.stawi.org/role-database" = "false"
      }
      annotations = {
        "node.stawi.org/operator-note" = "default Spot pack ${local.default_machine_type}/${local.default_boot_disk_gb}GB; CNPG on OCI (role-database)"
      }
    }
  }

  # Disabled → no VMs. Non-empty inventory wins. Empty inventory seeds
  # the default pack only when workers are enabled.
  nodes_effective = (
    !local.workers_enabled ? {} :
    length(var.nodes) > 0 ? var.nodes :
    local.default_nodes
  )
}
