# tofu/modules/node-oracle/outputs.tf
output "node" {
  description = "Node contract consumed by layer 03. Cross-provider schema with provider-specific extensions: node-oracle adds public_ipv4 (NAT-mapped public IPv4 used for Flannel's public-ip-overwrite annotation); node-contabo adds ipv4_cidr/ipv4_gateway/ipv6_cidr/ipv6_gateway (read by layer 03's per-node-patch renderer to write a Talos LinkConfig). Common fields are name, role, provider, ipv4, ipv6, talos_endpoint, kubespan_endpoint, derived_labels, derived_annotations, instance_id, bastion_id, account_key, config_apply_source, image_apply_generation."
  value = {
    name                = var.name
    role                = var.role
    provider            = "oracle"
    ipv4                = local.ipv4
    ipv6                = local.ipv6
    public_ipv4         = local.public_ip
    talos_endpoint      = "127.0.0.1" # per-node port is determined by layer 03 when it opens bastion sessions
    kubespan_endpoint   = local.ipv4
    derived_labels      = local.derived_labels
    derived_annotations = local.derived_annotations
    instance_id         = oci_core_instance.this.id
    bastion_id          = var.bastion_id
    account_key         = var.account_key
    config_apply_source = "ci"
    # For OCI, image_id changes destroy+create the instance, so
    # oci_core_instance.this.id itself bumps — no separate gate needed.
    # Layer 03's config-hash consumer only needs a field whose value
    # changes on any image-level replacement; instance_id satisfies that.
    image_apply_generation = oci_core_instance.this.id
  }
}

# State-writer fields — consumed by oracle-account-infra's `nodes` output
# and ultimately written to state.yaml in R2.
output "id" { value = oci_core_instance.this.id }
output "shape" { value = var.shape }
output "ocpus" { value = var.ocpus }
output "memory_gb" { value = var.memory_gb }
output "region" { value = var.region }
output "ipv4" { value = local.ipv4 }
output "ipv6" { value = local.ipv6 }
output "public_ipv4" {
  value       = local.public_ip
  description = "OCI's NAT-mapped public IPv4 (distinct from output `ipv4`, which falls back to private when public is absent). Layer 03 renders this into the flannel.alpha.coreos.com/public-ip-overwrite annotation so cross-node VXLAN tunnels target the routable public IP."
}
output "private_ipv4" { value = local.private_ip }
