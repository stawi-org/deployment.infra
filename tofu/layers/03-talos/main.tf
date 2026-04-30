# tofu/layers/03-talos/main.tf
data "terraform_remote_state" "secrets" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/00-talos-secrets.tfstate"
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

# All three infra layers (contabo, oracle, onprem) are per-account:
# each entry in accounts.yaml's `<provider>:` list owns its own state
# file, so the matrix workflow can fail-isolate one account from the
# others. Read each one and merge their `nodes` outputs into the
# single map layer 03 already expects.
data "terraform_remote_state" "contabo" {
  for_each = toset(yamldecode(file("${path.module}/../../shared/accounts.yaml")).contabo)
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/01-contabo-infra-${each.key}.tfstate"
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
  # Fold per-account contabo states' `nodes` outputs into a single map
  # so the rest of layer 03 (which expects one merged contabo nodes
  # map) is unaffected by the per-account state split.
  contabo_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.contabo :
    try(s.outputs.nodes, {})
  ]...)
}

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


locals {
  # Upstream nodes come from each infra layer's tfstate.outputs.nodes —
  # typed in-memory crossing, no R2 state.yaml indirection. Each layer's
  # output already contains provider, role, ipv4, ipv6, image_apply_generation
  # and derived labels/annotations with the cross-layer contract shape.
  _raw_nodes = merge(
    local.contabo_outputs_nodes,
    local.oracle_outputs_nodes,
    local.onprem_outputs_nodes,
  )

  # Each layer's tfstate output already carries derived_labels,
  # derived_annotations, image_apply_generation, and
  # config_apply_source. Only aliasing needed: layer 03 code references
  # v.account (the node modules emit account_key).
  all_nodes_from_state = {
    for k, v in local._raw_nodes : k => merge(v, {
      account = try(v.account, try(v.account_key, ""))
    })
  }

  controlplane_nodes   = { for k, v in local.all_nodes_from_state : k => v if try(v.role, "") == "controlplane" }
  worker_nodes         = { for k, v in local.all_nodes_from_state : k => v if try(v.role, "") == "worker" }
  contabo_worker_nodes = { for k, v in local.worker_nodes : k => v if try(v.provider, "") == "contabo" }
  ci_applied_nodes     = { for k, v in local.all_nodes_from_state : k => v if try(v.config_apply_source, "") == "ci" }
  # Prefer a reachable CP when picking the bootstrap / kubeconfig host;
  # fall back to any CP if the reachable set is empty (shouldn't happen
  # in practice — that would mean no CPs can be talosctl-applied at all).
  bootstrap_node_key = length(local.direct_controlplane_nodes) > 0 ? keys(local.direct_controlplane_nodes)[0] : (length(local.controlplane_nodes) > 0 ? keys(local.controlplane_nodes)[0] : null)
  bootstrap_node     = local.bootstrap_node_key != null ? local.all_nodes_from_state[local.bootstrap_node_key] : null
  all_node_addresses = compact(flatten([
    for n in local.all_nodes_from_state : [
      try(n.ipv4, null),
      try(n.ipv6, null),
    ]
  ]))
}

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}
