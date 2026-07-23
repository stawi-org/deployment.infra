# tofu/layers/04-dns/main.tf
#
# Reads each upstream infra layer's `nodes` output across every
# account (Contabo + Oracle + on-prem + GCP), folds them into one map
# keyed by globally-unique node name, then feeds the LB-tagged subset
# into dns.tf which publishes prod.<zone> round-robin records.
#
# Identical state-read shape to 03-talos/main.tf — DNS does not depend
# on 03-talos's tfstate so a talos apply failure does not block this layer.

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
  contabo_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.contabo :
    try(s.outputs.nodes, {})
  ]...)
  oracle_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.oracle :
    try(s.outputs.nodes, {})
  ]...)
  onprem_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.onprem :
    try(s.outputs.nodes, {})
  ]...)
  gcp_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.gcp :
    try(s.outputs.nodes, {})
  ]...)

  # All nodes across providers — the input set for the LB filter in
  # dns.tf. Same shape as 03-talos's local.all_nodes_from_state.
  all_nodes_from_state = merge(
    local.contabo_outputs_nodes,
    local.oracle_outputs_nodes,
    local.onprem_outputs_nodes,
    local.gcp_outputs_nodes,
  )
}
