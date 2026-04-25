# tofu/layers/02-oracle-infra/reconstruction.tf
#
# Request-file-driven reinstall mechanism (replaces the old
# per_node_force_recreate_generation map). See the equivalent file in
# layer 01-contabo-infra for the design rationale — same logic,
# applied to OCI nodes.

locals {
  reconstruction_dir = "${path.module}/../../../.github/reconstruction"

  reinstall_request_files = sort([
    for f in fileset(local.reconstruction_dir, "reinstall-*.yaml") :
    "${local.reconstruction_dir}/${f}"
  ])

  reinstall_requests = [
    for f in local.reinstall_request_files : merge(
      yamldecode(file(f)),
      { _file = f, _hash = sha1(file(f)) }
    )
  ]

  # Flatten {account_key => {node_key => ...}} into a flat set of
  # node_keys we need to evaluate. The accounts manifest is the
  # authoritative source; anything not in nodes.yaml gets "" (no-op).
  oci_node_keys = flatten([
    for k, v in local.oci_accounts_effective : keys(try(v.nodes, {}))
  ])

  per_node_reinstall_request_hash = {
    for k in local.oci_node_keys : k => try(
      [
        for r in reverse(local.reinstall_requests) : r._hash
        if try(r.scope, "") == "all" || contains(try(r.nodes, []), k)
      ][0],
      ""
    )
  }

  # Per-account view, shaped to match how oracle-account-infra
  # consumes per-node data — { account_key => { node_key => hash } }.
  per_account_reinstall_request_hashes = {
    for k, v in local.oci_accounts_effective : k => {
      for node_key, _ in try(v.nodes, {}) :
      node_key => local.per_node_reinstall_request_hash[node_key]
    }
  }
}
