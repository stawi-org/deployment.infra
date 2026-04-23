# tofu/layers/02-oracle-infra/outputs.tf
output "nodes" {
  description = "Aggregated worker node contracts from all OCI accounts."
  value = length(module.oracle_account) > 0 ? merge([
    for k, m in module.oracle_account : m.nodes
  ]...) : {}
}

output "bastion_sessions" {
  description = "Aggregated per-worker bastion port-forwarding sessions, keyed by globally-unique node name."
  value = length(module.oracle_account) > 0 ? merge([
    for k, m in module.oracle_account : m.bastion_sessions
  ]...) : {}
}

output "bastion_session_keys" {
  description = "Aggregated per-worker bastion SSH private keys, keyed by globally-unique node name."
  sensitive   = true
  value = length(module.oracle_account) > 0 ? merge([
    for k, m in module.oracle_account : m.bastion_session_keys
  ]...) : {}
}
