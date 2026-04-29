output "omni_url" {
  value       = "https://cp.antinvestor.com"
  description = "Public Omni endpoint."
}

output "omni_host_instance_id" {
  value = module.omni_host.instance_id
}

output "dex_omni_client_secret" {
  value     = module.omni_host.dex_omni_client_secret
  sensitive = true
}

output "siderolink_advertised_host" {
  value       = "cp.antinvestor.com"
  description = "Hostname downstream layers should use to construct siderolink URLs."
}
