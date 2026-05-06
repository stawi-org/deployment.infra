# tofu/layers/03-talos/per-node-patches.tf
#
# Renders per-node Talos patches from each upstream node's outputs
# and uploads them to R2. The sync-cluster-template workflow's
# scripts/apply-per-node-patches.sh (Task 10) reads them back,
# resolves each node's Omni machine-id, wraps in a
# ConfigPatches.omni.sidero.dev envelope, and applies. We don't
# wrap in tofu because machine-ids aren't known until Talos has
# registered via SideroLink — chicken and egg.
#
# R2 path: production/per-node-patches/<talos-version>/<node>.yaml.
# Cluster-scoped (top-level), distinct from node-state's per-node
# Talos machine configs which are <account>/<talos-version>/
# scoped. We use a layer-local aws_s3_object instead of extending
# node-state because the path shapes are incompatible.
#
# Provider scoping:
#   - contabo: render node-contabo.tftpl (LinkConfig + HostnameConfig
#              + nodeLabels/Annotations)
#   - oracle:  render node-oracle.tftpl (HostnameConfig +
#              nodeLabels/Annotations including flannel overrides)
#   - onprem:  skip (currently out of scope per 2026-05-03 spec)

locals {
  # Filter to providers we render patches for. On-prem nodes are
  # silently skipped — they currently aren't part of the cluster.
  per_node_patch_eligible = {
    for k, v in local.all_nodes_from_state : k => v
    if contains(["contabo", "oracle"], try(v.provider, ""))
  }

  # Render the right template per node based on provider. Each
  # entry's value is the rendered Talos patch YAML (no Omni
  # envelope yet).
  per_node_patches_rendered = {
    for k, v in local.per_node_patch_eligible : k => (
      v.provider == "contabo" ? templatefile(
        "${path.module}/../../shared/patches/node-contabo.tftpl",
        {
          hostname         = k
          node_labels      = try(v.derived_labels, {})
          node_annotations = try(v.derived_annotations, {})
          ipv4             = try(v.ipv4, "")
          ipv4_cidr        = try(v.ipv4_cidr, 0)
          ipv4_gateway     = try(v.ipv4_gateway, "")
          ipv6             = try(v.ipv6, "")
          ipv6_cidr        = try(v.ipv6_cidr, 0)
          ipv6_gateway     = try(v.ipv6_gateway, "")
          # Network form for kubelet validSubnets — first 4 hextets +
          # `::/64`. Mirrors antinvestor/deployments' working Jinja
          # equivalent: `host_v6.split(':')[:4] | join(':') + '::/64'`.
          # Works for both compressed (`2a02:c207:2272:7782::1`) and
          # expanded (`2a02:c207:2272:7782:0000:0000:0000:0001`) input
          # since the first 4 hextets are identical in either form.
          ipv6_network = try(v.ipv6, "") == "" ? "" : format(
            "%s::/%d",
            join(":", slice(split(":", v.ipv6), 0, 4)),
            try(v.ipv6_cidr, 64),
          )
        },
        ) : templatefile(
        "${path.module}/../../shared/patches/node-oracle.tftpl",
        {
          hostname         = k
          node_labels      = try(v.derived_labels, {})
          node_annotations = try(v.derived_annotations, {})
        },
      )
    )
  }

  per_node_patches_path_prefix = "production/per-node-patches/${var.talos_version}"
}

resource "aws_s3_object" "per_node_patch" {
  for_each = local.per_node_patches_rendered

  bucket       = "cluster-tofu-state"
  key          = "${local.per_node_patches_path_prefix}/${each.key}.yaml"
  content      = each.value
  content_type = "application/x-yaml"

  # Tag with sha for idempotency — rerender that doesn't change
  # the YAML is a no-op apply.
  metadata = {
    sha     = sha256(each.value)
    node    = each.key
    version = var.talos_version
  }

  # Defends against rendering a malformed LinkConfig if upstream
  # node-contabo state predates T4 (which added ipv4_cidr/gateway,
  # ipv6_cidr/gateway). Without this, a stale state would render
  # `address: <ip>/0, gateway: ""` — silently wrong. Layer-03's
  # tofu plan fails loud here so the operator re-applies the
  # affected node-contabo per-account state first.
  #
  # On-prem and oracle nodes are unaffected (oracle has no LinkConfig
  # docs in its template; on-prem is filtered out of
  # per_node_patch_eligible). Only Contabo nodes go through this
  # check.
  lifecycle {
    precondition {
      condition = (
        try(local.all_nodes_from_state[each.key].provider, "") != "contabo"
        ) || (
        try(local.all_nodes_from_state[each.key].ipv4, "") != "" &&
        try(local.all_nodes_from_state[each.key].ipv4_cidr, null) != null &&
        try(local.all_nodes_from_state[each.key].ipv4_gateway, "") != "" &&
        try(local.all_nodes_from_state[each.key].ipv6, "") != "" &&
        try(local.all_nodes_from_state[each.key].ipv6_cidr, null) != null &&
        try(local.all_nodes_from_state[each.key].ipv6_gateway, "") != ""
      )
      error_message = "Contabo node ${each.key} has incomplete network state in the upstream tfstate (one of ipv4/ipv4_cidr/ipv4_gateway/ipv6/ipv6_cidr/ipv6_gateway is null/empty). Re-apply the node-contabo's owning layer (01-contabo-infra-<account>) — its postcondition (added in T4) will refuse the apply if Contabo's API is returning incomplete data, or it will repopulate the output with the new schema if the state was simply pre-T4."
    }
  }
}
