output "instance_id" {
  description = "Contabo VPS instance ID hosting Omni."
  value       = contabo_instance.this.id
}

output "ipv4" {
  description = "Public IPv4 of the omni-host."
  value       = contabo_instance.this.ip_config[0].v4[0].ip
}

output "ipv6" {
  description = "Public IPv6 of the omni-host (null if v6 not assigned by Contabo)."
  value       = try(contabo_instance.this.ip_config[0].v6[0].ip, null)
}
