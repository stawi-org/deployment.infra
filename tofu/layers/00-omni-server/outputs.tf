output "omni_url" {
  value       = "https://cp.stawi.org"
  description = "Public Omni endpoint."
}

output "omni_host_instance_id" {
  value = coalescelist(
    module.omni_host_contabo[*].instance_id,
    module.omni_host_oci[*].instance_id,
  )[0]
}

output "siderolink_advertised_host" {
  value       = "cp.stawi.org"
  description = "Hostname downstream layers should use to construct siderolink URLs."
}
