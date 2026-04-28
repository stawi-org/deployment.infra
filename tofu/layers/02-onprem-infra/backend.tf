# tofu/layers/02-onprem-infra/backend.tf
#
# Partial backend: the state `key` is left unset in HCL and supplied at
# `tofu init` time via -backend-config="key=production/02-onprem-infra-<account>.tfstate".
# Each on-prem account (operator-run site) gets its own state file so a
# single account's apply failure (R2 sync hiccup, decryption issue,
# bad nodes.yaml shape) cannot block other accounts or downstream
# layers — the workflow runs accounts as a fail-fast=false matrix,
# each cell scoped to one key. Identical shape to 02-oracle-infra.
terraform {
  backend "s3" {
    bucket = "cluster-tofu-state"
    # endpoints.s3 provided at init time via -backend-config
    use_path_style              = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_lockfile                = true
  }
}
