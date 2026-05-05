# tofu/modules/node-contabo/outputs.tf
output "instance_id" { value = contabo_instance.this.id }
output "product_id" { value = contabo_instance.this.product_id }
output "region" { value = contabo_instance.this.region }
output "ipv4" { value = local.ipv4 }
output "ipv4_cidr" { value = local.ipv4_cidr }
output "ipv4_gateway" { value = local.ipv4_gateway }
output "ipv6" { value = local.ipv6 }
output "ipv6_cidr" { value = local.ipv6_cidr }
output "ipv6_gateway" { value = local.ipv6_gateway }
output "account_key" { value = var.account_key }
output "image_apply_generation" {
  value = md5("${contabo_instance.this.id}:${var.image_id}")
}

output "node" {
  description = "Node contract consumed by layer 03. Cross-provider schema with provider-specific extensions: node-oracle adds public_ipv4 (NAT-mapped public IPv4 used for Flannel's public-ip-overwrite annotation); node-contabo adds ipv4_cidr/ipv4_gateway/ipv6_cidr/ipv6_gateway (read by layer 03's per-node-patch renderer to write a Talos LinkConfig). Common fields are name, role, provider, ipv4, ipv6, talos_endpoint, kubespan_endpoint, derived_labels, derived_annotations, instance_id, bastion_id, account_key, config_apply_source, image_apply_generation."
  depends_on  = [null_resource.ensure_image]
  value = {
    name                   = var.name
    role                   = var.role
    provider               = "contabo"
    ipv4                   = local.ipv4
    ipv4_cidr              = local.ipv4_cidr
    ipv4_gateway           = local.ipv4_gateway
    ipv6                   = local.ipv6
    ipv6_cidr              = local.ipv6_cidr
    ipv6_gateway           = local.ipv6_gateway
    talos_endpoint         = "${local.ipv4}:50000"
    kubespan_endpoint      = local.ipv4
    derived_labels         = local.derived_labels
    derived_annotations    = local.derived_annotations
    instance_id            = contabo_instance.this.id
    bastion_id             = null
    account_key            = var.account_key
    config_apply_source    = "ci"
    image_apply_generation = md5("${contabo_instance.this.id}:${var.image_id}")
  }
}
