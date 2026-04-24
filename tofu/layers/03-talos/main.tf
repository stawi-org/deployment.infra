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

data "terraform_remote_state" "contabo" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/01-contabo-infra.tfstate"
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

data "terraform_remote_state" "oracle" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-oracle-infra.tfstate"
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

data "terraform_remote_state" "onprem" {
  backend = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-onprem-infra.tfstate"
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
  # Upstream nodes come from each infra layer's tfstate.outputs.nodes —
  # typed in-memory crossing, no R2 state.yaml indirection. Each layer's
  # output already contains provider, role, ipv4, ipv6, image_apply_generation
  # and derived labels/annotations with the cross-layer contract shape.
  _raw_nodes = merge(
    try(data.terraform_remote_state.contabo.outputs.nodes, {}),
    try(data.terraform_remote_state.oracle.outputs.nodes, {}),
    try(data.terraform_remote_state.onprem.outputs.nodes, {}),
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
  bootstrap_node       = length(local.controlplane_nodes) > 0 ? values(local.controlplane_nodes)[0] : null
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
