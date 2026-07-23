output "instance_id" {
  description = "GCE instance id."
  value       = google_compute_instance.omni.instance_id
}

output "self_link" {
  value = google_compute_instance.omni.self_link
}

output "ipv4" {
  description = "Static external IPv4 (reserved address)."
  value       = google_compute_address.omni.address
}

output "ipv6" {
  description = "IPv6 not enabled on this host in v1 (null)."
  value       = null
}

output "zone" {
  value = var.zone
}

output "machine_type" {
  value = var.machine_type
}
