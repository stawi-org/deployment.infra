# tofu/layers/03-talos/outputs.tf
data "talos_cluster_kubeconfig" "this" {
  # null_resource.wait_apiserver gates this on /healthz = ok, so the
  # kubeconfig we emit is guaranteed to hit a warm apiserver. Without
  # that gate, downstream layer 04-flux connect-refuses on 6443 because
  # kube-apiserver takes 60-180s to start after bootstrap returns.
  depends_on           = [null_resource.wait_apiserver]
  client_configuration = data.terraform_remote_state.secrets.outputs.client_configuration
  node                 = local.bootstrap_node.ipv4
  endpoint             = local.bootstrap_node.ipv4
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = data.terraform_remote_state.secrets.outputs.client_configuration
  endpoints            = [for n in local.controlplane_nodes : n.ipv4]
  nodes                = local.all_node_addresses
}

# Structured kubeconfig — downstream layers consume this directly rather than
# yamldecode-ing the raw string. The `host` field is overridden to the
# DNS-managed cluster endpoint so downstream consumers fail over across
# CPs (talos_cluster_kubeconfig returns whichever single CP IP the
# talos API gives us, which may be mid-reboot during config rollouts).
output "kubeconfig" {
  description = "Structured kubeconfig client configuration (host, ca_certificate, client_certificate, client_key). Consumed by layer 04."
  value = merge(
    data.talos_cluster_kubeconfig.this.kubernetes_client_configuration,
    { host = var.cluster_endpoint },
  )
  sensitive = true
}

# Raw YAML kubeconfig — for operators who need to `kubectl --kubeconfig <file>`.
output "kubeconfig_raw" {
  description = "Raw YAML kubeconfig string. Write to disk for operator use."
  value       = data.talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive   = true
}

output "kubernetes_endpoint" {
  description = "Kubernetes API endpoint URL (scheme://host:port)."
  value       = data.talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
}

output "talosconfig" {
  description = "Raw talosconfig file content (YAML). Consumed by the etcd-backup CronJob via a k8s Secret created in layer 04."
  value       = data.talos_client_configuration.this.talos_config
  sensitive   = true
}

# Rendered machine-config bundle — published as a workflow artifact so
# operators can join a non-cloud/on-prem machine to the cluster without
# re-running tofu. The generic_worker config has no platform-specific
# networking; the receiving machine uses DHCP/SLAAC on its own network
# and joins via outbound KubeSpan (no public IP required).
output "generic_worker_config" {
  description = "Platform-neutral Talos worker machine config. Apply with: talosctl apply-config --insecure -n <new-node-ip> -f generic-worker.yaml"
  value       = data.talos_machine_configuration.generic_worker.machine_configuration
  sensitive   = true
}

output "cp_machine_configs" {
  description = "Map of controlplane node name → rendered machine config. Useful for side-by-side diffing or manual reapplies."
  value       = { for k, c in data.talos_machine_configuration.cp : k => c.machine_configuration }
  sensitive   = true
}

output "worker_machine_configs" {
  description = "Map of worker node name → rendered machine config, including OCI and declared on-prem workers."
  value       = { for k, c in data.talos_machine_configuration.worker : k => c.machine_configuration }
  sensitive   = true
}
