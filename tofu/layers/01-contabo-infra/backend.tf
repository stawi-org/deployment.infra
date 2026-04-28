# tofu/layers/01-contabo-infra/backend.tf
#
# Partial backend: the state `key` is left unset in HCL and supplied at
# `tofu init` time via -backend-config="key=production/01-contabo-infra-<account>.tfstate".
# Each contabo account gets its own state file so a single account's
# apply failure (Contabo API auth blip, OAuth token rotation, image
# slot exhaustion, etc.) cannot block other accounts or downstream
# layers — the workflow runs accounts as a fail-fast=false matrix,
# each cell scoped to one key. Identical shape to 02-oracle-infra.
terraform {
  backend "s3" {
    bucket                      = "cluster-tofu-state"
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
