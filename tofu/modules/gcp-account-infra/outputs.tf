# tofu/modules/gcp-account-infra/outputs.tf

output "nodes" {
  description = "Map of GCP node contracts from this account, keyed by node_key as declared in inventory."
  value       = { for k, m in module.node : k => m.node }
}

output "nodes_state" {
  description = "Per-node metadata for the state writer, keyed by local node key."
  value = {
    for k, n in module.node : k => {
      id           = n.id
      self_link    = n.self_link
      machine_type = n.machine_type
      zone         = n.zone
      region       = n.region
      preemptible  = n.preemptible
      ipv4         = n.ipv4
      public_ipv4  = n.public_ipv4
      private_ipv4 = n.private_ipv4
    }
  }
}

output "network_id" {
  value = google_compute_network.this.id
}
