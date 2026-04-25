# tofu/modules/oracle-account-infra/outputs.tf
output "nodes" {
  description = "Map of OCI node contracts from this account, keyed by node_key as declared in inventory. Operators own key uniqueness across accounts — the keys already encode the account (e.g. oci-<acct>-node-1)."
  value       = { for k, m in module.node : k => m.node }
}

output "nodes_state" {
  description = "Per-node metadata for the state writer, keyed by local node key (without account prefix)."
  value = {
    for k, n in module.node : k => {
      id        = n.id
      shape     = n.shape
      ocpus     = n.ocpus
      memory_gb = n.memory_gb
      region    = var.region
      ipv4      = n.ipv4
      ipv6      = n.ipv6
    }
  }
}

output "bastion_id" {
  value = oci_bastion_bastion.this.id
}

output "vcn_id" {
  value = oci_core_vcn.this.id
}

output "bastion_sessions" {
  description = "Per-node bastion port-forwarding session details. Keys match the node_key in inventory."
  value = {
    for k, s in oci_bastion_session.node : k => {
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
    for k, key in tls_private_key.bastion : k => key.private_key_pem
  }
}
