output "instance_id" {
  description = "OCID of the omni-host instance."
  value       = oci_core_instance.this.id
}

output "ipv4" {
  description = "Ephemeral public IPv4 auto-assigned to the omni-host VNIC. Changes on instance recreate; tofu rewrites Cloudflare DNS on the same apply."
  value       = oci_core_instance.this.public_ip
}

output "ipv6" {
  description = "First IPv6 address assigned to the omni-host VNIC. Stable while the instance lives."
  value       = try(data.oci_core_vnic.this.ipv6addresses[0], null)
}
