# tofu/layers/01-contabo-infra/backend.tf
terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
    key                         = "production/01-contabo-infra.tfstate"
    region                      = "auto"
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = true
    encrypt                     = true
  }
}
