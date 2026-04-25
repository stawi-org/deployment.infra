# tofu/modules/node-contabo/outputs.tf
output "instance_id" { value = contabo_instance.this.id }
output "product_id" { value = contabo_instance.this.product_id }
output "region" { value = contabo_instance.this.region }
output "ipv4" { value = local.ipv4 }
output "ipv6" { value = local.ipv6 }
output "account_key" { value = var.account_key }
output "image_apply_generation" {
  value = md5("${contabo_instance.this.id}:${var.reinstall_request_hash}")
}

output "node" {
  description = "Node contract consumed by layer 03. Schema identical to modules/node-oracle."
  # depends_on ties this output (and therefore every downstream
  # consumer's config apply) to null_resource.ensure_image. Without
  # the gate, layer 03 could write a new Talos machine config over a
  # node that's mid-reinstall or still running the previous image.
  depends_on = [null_resource.ensure_image]
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
    # Bumps ONLY on events that actually wipe the disk:
    #   - new instance (contabo_instance.this.id changes)
    #   - new reinstall request applies to this node (var.reinstall_request_hash drifts)
    # Downstream (layer 03) folds this into its machine-config apply
    # hash so a wiped disk gets a fresh machine config applied + cluster
    # re-bootstrapped. Critically NOT keyed on null_resource.ensure_image.id,
    # because that changes on any trigger-schema change to the resource
    # itself — which would erroneously cascade config-reapply + re-bootstrap
    # through a healthy running cluster (killed a live cluster once already
    # when the trigger schema was refactored).
    image_apply_generation = md5("${contabo_instance.this.id}:${var.reinstall_request_hash}")
  }
}
