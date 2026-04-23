# tofu/modules/oracle-account-infra/outputs.tf
output "nodes" {
  description = "Map of OCI node contracts from this account, keyed by globally-unique name."
  value       = { for k, m in module.node : "${var.account_key}-${k}" => m.node }
}

output "bastion_id" {
  value = oci_bastion_bastion.this.id
}

output "vcn_id" {
  value = oci_core_vcn.this.id
}

output "bastion_sessions" {
  description = "Per-node bastion port-forwarding session details. Keys are globally-unique node names."
  value = {
    for k, s in oci_bastion_session.worker : "${var.account_key}-${k}" => {
      session_id     = s.id
      bastion_region = var.region
      target_ip      = module.node[k].node.ipv4
    }
  }
}

output "bastion_session_keys" {
  description = "Per-node SSH private keys for bastion sessions, PEM encoded. Sensitive."
  sensitive   = true
  value = {
    for k, key in tls_private_key.bastion : "${var.account_key}-${k}" => key.private_key_pem
  }
}
