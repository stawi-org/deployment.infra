output "instance_id" {
  description = "OCID of the omni-host instance."
  value       = oci_core_instance.this.id
}

output "ipv4" {
  description = "Ephemeral public IPv4 auto-assigned to the omni-host VNIC. Changes on instance recreate; tofu rewrites Cloudflare DNS on the same apply."
  # Read from the VNIC data source rather than oci_core_instance.this.public_ip
  # — the latter is empty in tofu's plan output for this layer (it stayed
  # null after the reserved-IP migration), while the VNIC datasource always
  # reflects the address OCI has currently bound to the primary private IP.
  value = data.oci_core_vnic.this.public_ip_address
}

output "ipv6" {
  description = "First IPv6 address assigned to the omni-host VNIC. Stable while the instance lives."
  value       = try(data.oci_core_vnic.this.ipv6addresses[0], null)
}
