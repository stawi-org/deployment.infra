# tofu/modules/oracle-account-infra/nodes.tf
#
# OCI nodes boot in Talos maintenance mode (no user_data). Layer 03's
# talos_machine_configuration_apply auto-falls back to insecure mode
# for the first config push, exactly the same pattern Contabo (ISO
# boot) and onprem nodes use. After that first apply Talos
# regenerates its API serving cert with whatever certSANs layer 03
# specifies, so subsequent applies use mTLS normally — no chicken-
# and-egg between user_data certSANs and the connection target.

module "node" {
  for_each = var.nodes
  source   = "../node-oracle"

  name                = each.key
  role                = each.value.role
  shape               = each.value.shape
  ocpus               = each.value.ocpus
  memory_gb           = each.value.memory_gb
  subnet_id           = oci_core_subnet.public.id
  image_id            = local.image_ocid
  compartment_ocid    = var.compartment_ocid
  assign_ipv6         = var.enable_ipv6
  availability_domain = local.ad_0
  labels              = merge(var.labels, each.value.labels)
  annotations         = merge(var.annotations, each.value.annotations)
  bastion_id          = oci_bastion_bastion.this.id
  account_key         = var.account_key
  region              = var.region
  reinstall_request_hash = lookup(
    var.per_node_reinstall_request_hash, each.key, ""
  )

  providers = { oci = oci }
}
