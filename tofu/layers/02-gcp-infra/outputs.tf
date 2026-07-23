# tofu/layers/02-gcp-infra/outputs.tf
#
# Aggregation note: with `for_each = local.gcp_accounts_effective` whose
# key set is statically computable, OpenTofu types `module.gcp_account`
# as an object rather than a uniform map. Each instance's `nodes` output
# is `{ for k in module.node : k => m.node }` so the OBJECT attribute
# keys differ per account. merge() can't unify a tuple of differently-
# attributed objects, so we coerce each instance's output to a map() of
# the (uniform) node-contract value type before merging. tomap() succeeds
# because the *value* type is identical across accounts (single module),
# only the keys differ — which is exactly what map vs object captures.
output "nodes" {
  description = "GCP node contracts for this account cell."
  value = merge([
    for k, m in module.gcp_account : tomap(m.nodes)
  ]...)
}
