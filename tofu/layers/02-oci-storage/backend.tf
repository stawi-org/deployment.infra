# tofu/layers/02-oci-storage/backend.tf
#
# Single-tenancy storage layer (bwire-only) — no per-account matrix.
# Backend key is fixed at production/02-oci-storage.tfstate; the
# `account` input to tofu-layer.yml stays empty for this layer.
terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-oci-storage.tfstate"
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
