output "omni_url" {
  value       = "https://cp.antinvestor.com"
  description = "Public Omni endpoint."
}

output "omni_host_instance_id" {
  value = module.omni_host_oci.instance_id
}

output "siderolink_advertised_host" {
  value       = "cp.antinvestor.com"
  description = "Hostname downstream layers should use to construct siderolink URLs."
}
