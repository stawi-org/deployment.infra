# NOTE: The KittyKatt/omni provider does not expose siderolink_join_url or
# talosconfig as cluster resource attributes. The cluster resource's computed
# output is the full YAML template only. siderolink_url must be obtained via
# `omnictl cluster siderolink-url stawi-cluster` after Phase B apply.
# talosconfig must be obtained via `omnictl talosconfig --cluster stawi-cluster`.

output "siderolink_url" {
  value       = ""
  sensitive   = true
  description = "Populated manually after Phase B apply: omnictl cluster siderolink-url stawi-cluster. Required for kernel cmdline injection into Talos nodes."
}

output "kubeconfig" {
  value       = try(omni_cluster_kubeconfig.stawi.yaml, "")
  sensitive   = true
  description = "Kubeconfig for stawi-cluster, delivered by Omni. Available after cluster bootstraps in Phase B."
}

output "talosconfig" {
  value       = ""
  sensitive   = true
  description = "Populated manually after Phase B apply: omnictl talosconfig --cluster stawi-cluster."
}

output "cluster_name" {
  value       = omni_cluster.stawi.id
  description = "Omni cluster ID (name)."
}

output "cluster_yaml" {
  value       = try(omni_cluster.stawi.yaml, "")
  sensitive   = true
  description = "Full YAML document describing the cluster template as rendered by Omni."
}
