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

locals {
  all_nodes = merge(
    data.terraform_remote_state.contabo.outputs.nodes,
    data.terraform_remote_state.oracle.outputs.nodes,
  )

  controlplane_nodes = { for k, v in local.all_nodes : k => v if v.role == "controlplane" }
  worker_nodes       = { for k, v in local.all_nodes : k => v if v.role == "worker" }
  ci_applied_nodes   = { for k, v in local.all_nodes : k => v if v.config_apply_source == "ci" }
  bootstrap_node     = values(local.controlplane_nodes)[0]
}
