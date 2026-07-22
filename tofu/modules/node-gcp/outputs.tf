# tofu/modules/node-gcp/outputs.tf
output "node" {
  description = "Node contract consumed by layer 03. Cross-provider schema with provider-specific extensions. Common fields are name, role, provider, ipv4, ipv6, public_ipv4, private_ipv4, talos_endpoint, kubespan_endpoint, derived_labels, derived_annotations, instance_id, bastion_id, account_key, config_apply_source, image_apply_generation."
  value = {
    name         = var.name
    role         = var.role
    provider     = "gcp"
    ipv4         = local.ipv4
    ipv6         = null
    public_ipv4  = local.public_ip
    private_ipv4 = local.private_ip
    # No bastion: CI and Omni reach the node on its public (or private) IPv4.
    talos_endpoint      = local.ipv4
    kubespan_endpoint   = local.ipv4
    derived_labels      = local.derived_labels
    derived_annotations = local.derived_annotations
    instance_id         = google_compute_instance.this.id
    bastion_id          = null
    account_key         = var.account_key
    config_apply_source = "ci"
    # instance_id (numeric GCE id) changes on every recreate — same role
    # as oci_core_instance.this.id for layer 03's image-apply gate.
    image_apply_generation = google_compute_instance.this.instance_id
  }
}

# State-writer fields — consumed by gcp-account-infra and written to
# state.yaml in R2.
output "id" { value = google_compute_instance.this.id }
output "self_link" { value = google_compute_instance.this.self_link }
output "machine_type" { value = var.machine_type }
output "zone" { value = var.zone }
output "region" { value = var.region }
output "preemptible" { value = var.preemptible }
output "ipv4" { value = local.ipv4 }
output "public_ipv4" {
  value       = local.public_ip
  description = "GCE ephemeral public IPv4 (NAT). Distinct from output ipv4, which falls back to private when public is absent. Layer 03 renders this into flannel.alpha.coreos.com/public-ip-overwrite."
}
output "private_ipv4" { value = local.private_ip }
