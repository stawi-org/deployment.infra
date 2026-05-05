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
}
