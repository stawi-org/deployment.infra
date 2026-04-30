# tofu/layers/03-talos/outputs.tf
#
# Talos kubeconfig / talosconfig / machine-config outputs were retired
# when the bootstrap path moved from talosctl to Omni. Operators get
# kubeconfig via `omnictl kubeconfig --cluster stawi`, talosconfig via
# `omnictl talosconfig --cluster stawi`. The dns.tf debug outputs
# remain (defined alongside the import block in dns.tf).

output "controlplane_node_keys" {
  description = "Sorted list of control-plane node keys (provider-account-node-N) the cluster knows about. Diagnostic — pairs with cluster.tf's machine-label sync."
  value       = sort(keys(local.controlplane_nodes))
}

output "worker_node_keys" {
  description = "Sorted list of worker node keys. Diagnostic."
  value       = sort(keys(local.worker_nodes))
}

output "loadbalancer_node_keys" {
  description = "Nodes carrying node.kubernetes.io/external-load-balancer=\"true\" — these IPs land in prod.<zone>."
  value       = sort(keys(local.lb_nodes))
}
