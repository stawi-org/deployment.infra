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


module "contabo_state" {
  for_each            = toset(local.accounts_manifest.contabo)
  source              = "../../modules/node-state"
  provider_name       = "contabo"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

module "oracle_state" {
  for_each            = toset(local.accounts_manifest.oracle)
  source              = "../../modules/node-state"
  provider_name       = "oracle"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

module "onprem_state" {
  for_each            = toset(local.accounts_manifest.onprem)
  source              = "../../modules/node-state"
  provider_name       = "onprem"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

locals {
  # All nodes regardless of provider, keyed by node_key.
  # Each value carries provider, account, role, labels, annotations, and
  # address info sufficient for rendering and applying Talos config.
  all_nodes_from_state = merge(flatten([
    [
      for acct_key, mod in module.contabo_state : {
        for node_key, node in try(mod.state.nodes, {}) :
        (node_key) => merge(
          { provider = "contabo", account = acct_key },
          try(mod.nodes.nodes[node_key], {}),
          node.provider_data,
        )
      }
    ],
    [
      for acct_key, mod in module.oracle_state : {
        for node_key, node in try(mod.state.nodes, {}) :
        "${acct_key}-${node_key}" => merge(
          { provider = "oracle", account = acct_key },
          try(mod.nodes.nodes[node_key], {}),
          node.provider_data,
        )
      }
    ],
    [
      for acct_key, mod in module.onprem_state : {
        for node_key, node in try(mod.state.nodes, {}) :
        "${acct_key}-${node_key}" => merge(
          { provider = "onprem", account = acct_key },
          try(mod.nodes.nodes[node_key], {}),
          node.provider_data,
        )
      }
    ],
  ])...)

  # Flat map of upstream talos state across providers, keyed by node_key
  # (same key used in all_nodes_from_state).
  upstream_talos_state = merge(
    { for acct_key, mod in module.contabo_state :
    acct_key => try(mod.talos_state.nodes, {}) },
    { for acct_key, mod in module.oracle_state :
    acct_key => try(mod.talos_state.nodes, {}) },
    { for acct_key, mod in module.onprem_state :
    acct_key => try(mod.talos_state.nodes, {}) },
  )

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
