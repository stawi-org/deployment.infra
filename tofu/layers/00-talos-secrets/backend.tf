# tofu/layers/00-talos-secrets/backend.tf
terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
    key                         = "production/00-talos-secrets.tfstate"
    region                      = "auto"
    # endpoints.s3 provided at init time via -backend-config
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
