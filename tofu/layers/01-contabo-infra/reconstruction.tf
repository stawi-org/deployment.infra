# tofu/layers/01-contabo-infra/reconstruction.tf
#
# Request-file-driven reinstall mechanism (replaces the old integer
# force_reinstall_generation and per_node_force_reinstall_generation
# tfvars).
#
# `.github/reconstruction/reinstall-*.yaml` files are written by the
# tofu-reconstruct workflow and merged into main via PR. Each file
# captures one cluster-state-altering request:
#
#   operation: reinstall
#   scope: all | selected
#   nodes: ["<node_key>", ...]   # required when scope=selected
#   reason: "..."
#
# This file produces:
#   - local.per_node_reinstall_request_hash[node_key]
#       The SHA1 of the latest applicable reinstall-request file for
#       this node (or "" if none applies). Drives the per-node
#       null_resource.ensure_image trigger; new request → trigger drift
#       → script re-runs in MODE=reinstall and wipes the disk.
#   - local.cluster_wide_reinstall_marker
#       SHA1 of the concatenation of all scope=all request hashes (or
#       "" if none). Drives image-replacement (so per-node PUTs land a
#       new imageId and aren't no-op'd by Contabo) and is exported as
#       the cluster_reinstall_marker output that layer 03 watches to
#       re-fire bootstrap when every CP was wiped together.

locals {
  reconstruction_dir = "${path.module}/../../../.github/reconstruction"

  # Lexicographic sort = chronological because filenames embed UTC
  # timestamps. Latest applicable request wins via the [0] pick after
  # reversing.
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

  # Per-node hash. Empty if no request applies (the script then runs
  # MODE=verify, a no-op for steady-state nodes).
  per_node_reinstall_request_hash = {
    for k, _ in local.contabo_nodes : k => try(
      [
        for r in reverse(local.reinstall_requests) : r._hash
        if try(r.scope, "") == "all" || contains(try(r.nodes, []), k)
      ][0],
      ""
    )
  }

  # Cluster-wide marker — only scope=all requests count. Per-node
  # requests deliberately don't affect this; they wipe one node while
  # the cluster keeps quorum, so layer 03 must NOT re-bootstrap.
  cluster_wide_reinstall_marker = sha1(jsonencode([
    for r in local.reinstall_requests : r._hash if try(r.scope, "") == "all"
  ]))

  # Image-replacement marker — fires on ANY reinstall request (cluster-
  # wide or per-node). Reason: Contabo's PUT /compute/instances/{id}
  # is a no-op when imageId equals the live instance's imageId, so
  # every reinstall PUT needs a fresh imageId. Bumping this on per-
  # node requests too keeps the PUT non-no-op.
  any_reinstall_marker = sha1(jsonencode([
    for r in local.reinstall_requests : r._hash
  ]))
}
