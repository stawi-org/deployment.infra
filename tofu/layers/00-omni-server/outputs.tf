output "omni_url" {
  value       = "https://cp.antinvestor.com"
  description = "Public Omni endpoint."
}

output "omni_host_ipv4" {
  value = module.omni_host.ipv4
}

output "omni_host_ipv6" {
  value = module.omni_host.ipv6
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.omni.id
}

output "dex_omni_client_secret" {
  value     = module.omni_host.dex_omni_client_secret
  sensitive = true
}

output "siderolink_advertised_host" {
  value       = "cp.antinvestor.com"
  description = "Hostname downstream layers should use to construct siderolink URLs."
}
