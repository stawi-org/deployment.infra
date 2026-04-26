# tofu/layers/02-oracle-infra/outputs.tf
#
# Aggregation note: with `for_each = local.oci_accounts_effective` whose
# key set is statically computable, OpenTofu types `module.oracle_account`
# as `object({<acct1> = ..., <acct2> = ...})` rather than a uniform map.
# Each instance's `nodes` output is `{ for k in module.node : k => m.node }`
# so the OBJECT attribute keys differ per account (oci-bwire-node-1 vs
# oci-brianelvis33-node-1 etc). merge() can't unify a tuple of differently-
# attributed objects, so we coerce each instance's output to a map() of
# the (uniform) node-contract value type before merging. tomap() succeeds
# because the *value* type is identical across accounts (single module),
# only the keys differ — which is exactly what map vs object captures.
output "nodes" {
  description = "Aggregated OCI node contracts from all OCI accounts."
  value = merge([
    for k, m in module.oracle_account : tomap(m.nodes)
  ]...)
}

output "bastion_sessions" {
  description = "Aggregated per-node bastion port-forwarding sessions, keyed by globally-unique node name."
  value = merge([
    for k, m in module.oracle_account : tomap(m.bastion_sessions)
  ]...)
}

output "bastion_session_keys" {
  description = "Aggregated per-node bastion SSH private keys, keyed by globally-unique node name."
  sensitive   = true
  value = merge([
    for k, m in module.oracle_account : tomap(m.bastion_session_keys)
  ]...)
}
