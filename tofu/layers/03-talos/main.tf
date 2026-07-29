# tofu/layers/03-talos/main.tf
#
# Reads each upstream infra layer's `nodes` output across every account
# (Oracle + on-prem + GCP), folds them into one map keyed by the
# globally-unique node name, and feeds two things downstream:
#
#   - dns.tf publishes cp-N + prod.<zone> records (cross-provider).
#   - cluster.tf drives Omni: applies machine-classes, syncs cluster
#     template, and labels each registered Omni Machine with this
#     node's derived_labels.
#
# Contabo was removed (fleet cut off). Active compute: OCI + GCP.
#
# 00-talos-secrets is no longer read here — Talos cluster secrets
# (PKI, etcd, kubelet) are owned by Omni now, not by tofu.

# Infra layers (oracle, onprem, gcp) are per-account: each entry in
# accounts.yaml's `<provider>:` list owns its own state file, so the
# matrix workflow can fail-isolate one account from the others. Read
# each one and merge their `nodes` outputs into the single map layer
# 03 already expects.
data "terraform_remote_state" "oracle" {
  for_each = toset(yamldecode(file("${path.module}/../../shared/accounts.yaml")).oracle)
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-oracle-infra-${each.key}.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

locals {
  # Fold per-account oracle states' `nodes` outputs into a single map
  # so the rest of layer 03 (which expects one merged oracle nodes map)
  # is unaffected by the per-account state split.
  oracle_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.oracle :
    try(s.outputs.nodes, {})
  ]...)
}

data "terraform_remote_state" "onprem" {
  for_each = toset(yamldecode(file("${path.module}/../../shared/accounts.yaml")).onprem)
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-onprem-infra-${each.key}.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

locals {
  # Same per-account merge as the others — single map keyed by node
  # name across all on-prem accounts.
  onprem_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.onprem :
    try(s.outputs.nodes, {})
  ]...)
}

data "terraform_remote_state" "gcp" {
  for_each = toset(try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).gcp, []))
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-gcp-infra-${each.key}.tfstate"
    region                      = "auto"
    endpoints                   = { s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com" }
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
  }
}

locals {
  gcp_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.gcp :
    try(s.outputs.nodes, {})
  ]...)
}


locals {
  # R2 inventory provider_data per node (all providers). Used as a
  # FALLBACK under tfstate outputs so:
  #   - pre-schema tfstate still renders patches
  #   - omni_machine_id pins written by reconcile-omni-machine-ids
  #     are visible to layer-03 label/patch matching without waiting
  #     for the next infra-layer apply
  #   - operator hand-edits via patch-inventory-node surface before
  #     the next infra-layer apply
  _inventory_account_pairs = flatten([
    for provider, accts in {
      oracle = try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).oracle, [])
      onprem = try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).onprem, [])
      gcp    = try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).gcp, [])
      } : [
      for acct in accts : { provider = provider, account = acct }
    ]
  ])

  inventory_provider_data = merge([
    for pair in local._inventory_account_pairs : try(
      {
        for node_name, node_decl in try(
          yamldecode(file("${var.local_inventory_dir}/${pair.provider}/${pair.account}/nodes.yaml")).nodes,
          {},
        ) : node_name => try(node_decl.provider_data, {})
      },
      {},
    )
  ]...)

  # Upstream nodes come from each infra layer's tfstate.outputs.nodes —
  # typed in-memory crossing, no R2 state.yaml indirection. Each layer's
  # output already contains provider, role, ipv4, ipv6, image_apply_generation
  # and derived labels/annotations with the cross-layer contract shape.
  # Per-node, fall back to R2 inventory provider_data so a stale
  # tfstate doesn't break the per-node-patch render, and so
  # omni_machine_id pins surface into matching.
  _raw_nodes = {
    for k, v in merge(
      local.oracle_outputs_nodes,
      local.onprem_outputs_nodes,
      local.gcp_outputs_nodes,
      ) : k => merge(
      try(local.inventory_provider_data[k], {}),
      v,
      # Explicit top-level pin for scripts that read omni_machine_id
      # without digging into provider_data.
      {
        omni_machine_id = try(
          v.omni_machine_id,
          try(local.inventory_provider_data[k].omni_machine_id, ""),
        )
      },
    )
  }

  # Each layer's tfstate output already carries derived_labels,
  # derived_annotations, image_apply_generation, and
  # config_apply_source. Only aliasing needed: layer 03 code references
  # v.account (the node modules emit account_key).
  all_nodes_from_state = {
    for k, v in local._raw_nodes : k => merge(v, {
      account = try(v.account, try(v.account_key, ""))
    })
  }

  controlplane_nodes = { for k, v in local.all_nodes_from_state : k => v if try(v.role, "") == "controlplane" }
  worker_nodes       = { for k, v in local.all_nodes_from_state : k => v if try(v.role, "") == "worker" }
}

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}
