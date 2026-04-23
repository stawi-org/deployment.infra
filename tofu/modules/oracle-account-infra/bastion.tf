# tofu/modules/oracle-account-infra/bastion.tf
# Note: bastion sessions additionally require SSH key authentication, so even with a
# permissive CIDR the session targets one node+port and rejects connections without
# the per-session key. Still, narrowing the CIDR to known operator/runner ranges is
# a defense-in-depth improvement — set var.bastion_client_cidr_block_allow_list at
# the caller (layer 02 oci_accounts entry) to override the default.
resource "oci_bastion_bastion" "this" {
  compartment_id               = var.compartment_ocid
  bastion_type                 = "STANDARD"
  name                         = "cluster-bastion-${var.account_key}"
  target_subnet_id             = oci_core_subnet.private.id
  client_cidr_block_allow_list = var.bastion_client_cidr_block_allow_list
  max_session_ttl_in_seconds   = 10800 # 3h max per session
}

# Per-worker SSH keypair used to authenticate the port-forwarding session.
# Fresh keys every tofu apply is fine — sessions last ≤3h anyway.
resource "tls_private_key" "bastion" {
  for_each  = var.workers
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Per-worker port-forwarding session. layer 03 consumes .id + the region to construct
# the SSH jump string `<session-id>@host.bastion.<region>.oci.oraclecloud.com`.
resource "oci_bastion_session" "worker" {
  for_each               = var.workers
  bastion_id             = oci_bastion_bastion.this.id
  display_name           = "talos-apply-${each.key}"
  session_ttl_in_seconds = 10800

  key_details {
    public_key_content = tls_private_key.bastion[each.key].public_key_openssh
  }

  target_resource_details {
    session_type                       = "PORT_FORWARDING"
    target_resource_private_ip_address = module.node[each.key].node.ipv4
    target_resource_port               = 50000
  }
}
