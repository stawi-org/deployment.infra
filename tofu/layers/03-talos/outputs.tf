# tofu/layers/03-talos/outputs.tf
#
# Talos kubeconfig / talosconfig / machine-config outputs were retired
# when the bootstrap path moved from talosctl to Omni. Operators get
# kubeconfig via `omnictl kubeconfig --cluster stawi`, talosconfig via
# `omnictl talosconfig --cluster stawi`. DNS outputs moved to 04-dns
# (2026-05).

output "controlplane_node_keys" {
  description = "Sorted list of control-plane node keys (provider-account-node-N) the cluster knows about. Diagnostic — pairs with cluster.tf's machine-label sync."
  value       = sort(keys(local.controlplane_nodes))
}

output "worker_node_keys" {
  description = "Sorted list of worker node keys. Diagnostic."
  value       = sort(keys(local.worker_nodes))
}
