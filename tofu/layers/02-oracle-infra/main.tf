# tofu/layers/02-oracle-infra/main.tf
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

locals {
  oci_provider_accounts = merge(var.retained_oci_accounts, var.oci_accounts)
}

# Each oci_accounts entry gets its own provider alias that reads a matching
# named profile from ~/.oci/config. The workflow's OCI workload-identity
# federation step writes one profile per account (profile name == map key,
# e.g. "stawi", "acctB"), each holding that tenancy's session-token-based auth.
#
# For local dev without WIF, each profile in ~/.oci/config uses API key auth
# (auth = "ApiKey"); the provider picks whichever credential type the profile
# holds via SecurityToken autodetection.
provider "oci" {
  for_each            = local.oci_provider_accounts
  alias               = "account"
  tenancy_ocid        = each.value.tenancy_ocid
  region              = each.value.region
  config_file_profile = each.key
  auth                = "SecurityToken"
}

module "oracle_account" {
  for_each  = var.oci_accounts
  source    = "../../modules/oracle-account-infra"
  providers = { oci = oci.account[each.key] }

  account_key                          = each.key
  compartment_ocid                     = each.value.compartment_ocid
  region                               = each.value.region
  vcn_cidr                             = each.value.vcn_cidr
  enable_ipv6                          = each.value.enable_ipv6
  workers                              = each.value.workers
  labels                               = each.value.labels
  annotations                          = each.value.annotations
  bastion_client_cidr_block_allow_list = each.value.bastion_client_cidr_block_allow_list
  cluster_name                         = var.cluster_name
  cluster_endpoint                     = var.cluster_endpoint
  talos_version                        = var.talos_version
  kubernetes_version                   = var.kubernetes_version
  machine_secrets                      = data.terraform_remote_state.secrets.outputs.machine_secrets
  shared_patches_dir                   = "${path.module}/../../shared/patches"
}
