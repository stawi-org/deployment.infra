# tofu/modules/node-oracle/outputs.tf
output "node" {
  description = "Node contract consumed by layer 03. Schema identical to modules/node-contabo."
  value = {
    name                = var.name
    role                = var.role
    provider            = "oracle"
    ipv4                = local.private_ip
    ipv6                = local.ipv6
    talos_endpoint      = "127.0.0.1" # per-node port is determined by layer 03 when it opens bastion sessions
    kubespan_endpoint   = local.private_ip
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
output "ipv4" { value = local.private_ip }
output "ipv6" { value = local.ipv6 }
