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
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
}

# node-state: R2-backed inventory read. Populated initially by
# scripts/seed-inventory.sh; kept in sync by this layer's writers.
module "oracle_account_state" {
  for_each            = toset(local.accounts_manifest.oracle)
  source              = "../../modules/node-state"
  provider_name       = "oracle"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

locals {
  oracle_account_keys = local.accounts_manifest.oracle

  oracle_auth_from_module = {
    for k, mod in module.oracle_account_state : k => try(mod.auth.auth, null)
  }
  oracle_nodes_from_module = {
    for k, mod in module.oracle_account_state : k => try(mod.nodes.nodes, {})
  }

  oci_accounts_effective = {
    for k in local.oracle_account_keys : k => merge(
      try(local.oracle_auth_from_module[k], {}),
      { nodes = local.oracle_nodes_from_module[k] }
    )
  }
}

# Each oracle account gets its own provider alias. The for_each key set is
# statically computable from accounts.yaml (a file read, not a computed value).
# Auth fields are sourced from the decrypted auth.yaml read via node-state.
locals {
  oci_provider_accounts = toset(local.oracle_account_keys)
}

# Each oci_accounts entry gets its own provider alias that reads auth from R2.
# For local dev without WIF, the config_file_profile fallback is used.
provider "oci" {
  for_each            = local.oci_provider_accounts
  alias               = "account"
  tenancy_ocid        = try(local.oracle_auth_from_module[each.key].tenancy_ocid, null)
  region              = try(local.oracle_auth_from_module[each.key].region, null)
  config_file_profile = try(local.oracle_auth_from_module[each.key].config_file_profile, each.key)
  auth                = try(local.oracle_auth_from_module[each.key].auth_method, "SecurityToken")
}

module "oracle_account" {
  for_each  = local.oci_accounts_effective
  source    = "../../modules/oracle-account-infra"
  providers = { oci = oci.account[each.key] }

  account_key                          = each.key
  compartment_ocid                     = try(each.value.compartment_ocid, "")
  region                               = try(each.value.region, "")
  vcn_cidr                             = try(each.value.vcn_cidr, "10.0.0.0/16")
  enable_ipv6                          = try(each.value.enable_ipv6, true)
  nodes                                = try(each.value.nodes, {})
  labels                               = try(each.value.labels, {})
  annotations                          = try(each.value.annotations, {})
  bastion_client_cidr_block_allow_list = try(each.value.bastion_client_cidr_block_allow_list, ["0.0.0.0/0"])
  cluster_name                         = var.cluster_name
  cluster_endpoint                     = var.cluster_endpoint
  talos_version                        = var.talos_version
  talos_image_source_uri               = try(var.talos_image_source_uris[each.key], null)
  talos_qcow2_local_path               = var.talos_qcow2_local_path
  force_image_generation               = var.force_image_generation
  kubernetes_version                   = var.kubernetes_version
  machine_secrets                      = data.terraform_remote_state.secrets.outputs.machine_secrets
  shared_patches_dir                   = "${path.module}/../../shared/patches"
}
