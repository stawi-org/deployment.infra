# tofu/modules/gcp-account-infra/defaults.tf
#
# Desired-state defaults live here — not in Python seed scripts.
# Empty R2 inventory (or nodes: {}) → two Spot workers. Operators
# still override by writing a non-empty nodes map to R2; the next
# apply uses that map as-is and the nodes-writer persists it.

locals {
  default_machine_type = "e2-medium"
  default_boot_disk_gb = 50
  default_node_count   = 2
  default_zone         = "${var.region}-b"

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
      }
      annotations = {
        "node.stawi.org/operator-note" = "default Spot pack ${local.default_machine_type}/${local.default_boot_disk_gb}GB"
      }
    }
  }

  # Inventory wins when non-empty; otherwise seed the default pack.
  nodes_effective = length(var.nodes) > 0 ? var.nodes : local.default_nodes
}
