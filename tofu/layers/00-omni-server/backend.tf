terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
    key                         = "production/00-omni-server.tfstate"
    region                      = "auto"
    encrypt                     = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    use_path_style              = true
  }
}
