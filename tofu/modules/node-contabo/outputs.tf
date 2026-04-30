# tofu/modules/node-contabo/outputs.tf
output "instance_id" { value = contabo_instance.this.id }
output "product_id" { value = contabo_instance.this.product_id }
output "region" { value = contabo_instance.this.region }
output "ipv4" { value = local.ipv4 }
output "ipv6" { value = local.ipv6 }
output "account_key" { value = var.account_key }
output "image_apply_generation" {
  value = md5("${contabo_instance.this.id}:${var.image_id}")
}

output "node" {
  description = "Node contract consumed by layer 03. Schema identical to modules/node-oracle."
  depends_on  = [null_resource.ensure_image]
  value = {
    name                = var.name
    role                = var.role
    provider            = "contabo"
    ipv4                = local.ipv4
    ipv6                = local.ipv6
    talos_endpoint      = "${local.ipv4}:50000"
    kubespan_endpoint   = local.ipv4
    derived_labels      = local.derived_labels
    derived_annotations = local.derived_annotations
    instance_id         = contabo_instance.this.id
    bastion_id          = null
    account_key         = var.account_key
    config_apply_source = "ci"
    # Bumps when the disk is on a new image (instance id changes
    # OR var.image_id drifts to a new contabo_image UUID).
    image_apply_generation = md5("${contabo_instance.this.id}:${var.image_id}")
  }
}
