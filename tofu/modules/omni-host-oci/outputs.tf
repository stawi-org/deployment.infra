output "instance_id" {
  description = "OCID of the omni-host instance."
  value       = oci_core_instance.this.id
}

output "ipv4" {
  description = "Reserved public IPv4 attached to the omni-host VNIC."
  value       = oci_core_public_ip.this.ip_address
}

output "ipv6" {
  description = "First IPv6 address assigned to the omni-host VNIC. Stable while the instance lives."
  value       = try(data.oci_core_vnic.this.ipv6addresses[0], null)
}
