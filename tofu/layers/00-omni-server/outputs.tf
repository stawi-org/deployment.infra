output "omni_url" {
  value       = "https://cp.stawi.org"
  description = "Public Omni endpoint."
}

output "omni_host_instance_id" {
  value = coalescelist(
    module.omni_host_contabo[*].instance_id,
    module.omni_host_oci[*].instance_id,
    module.omni_host_gcp[*].instance_id,
  )[0]
}

output "omni_host_ipv4" {
  value       = local.omni_host_ipv4
  description = "Public IPv4 of the active Omni substrate."
}

output "omni_host_provider" {
  value = var.omni_host_provider
}

output "siderolink_advertised_host" {
  value       = "cp.stawi.org"
  description = "Hostname downstream layers should use to construct siderolink URLs."
}
