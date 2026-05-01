# tofu/layers/02-oracle-infra/main.tf
#
# This layer provisions OCI infrastructure (VCN, subnets, security
# lists, instances, custom Talos image). It does NOT generate or push
# Talos machine configs — OCI nodes boot into maintenance mode (no
# user_data) and layer 03 owns all cluster-level configuration via
# talos_machine_configuration_apply with insecure-mode auto-fallback,
# the same flow Contabo + onprem use.

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))

  # Per-account state: this layer instance manages exactly one oracle
  # account, scoped by var.account_key. The downstream for_each blocks
  # (modules, providers, imports, writers) iterate over
  # local.oracle_account_keys, so they keep working unchanged — just
  # with a single entry. Resource addresses (module.oracle_account["bwire"]
  # etc.) stay valid for existing state.
  oracle_account_keys = [var.account_key]
}

# node-state: R2-backed inventory read. Populated initially by
# scripts/seed-inventory.sh; kept in sync by this layer's writers.
module "oracle_account_state" {
  for_each            = toset(local.oracle_account_keys)
  source              = "../../modules/node-state"
  provider_name       = "oracle"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

locals {
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
# config_file_profile = each.key because configure-oci-wif.sh names the
# ~/.oci/config profile after the account's R2 directory (which IS the
# account_key). Honoring a config_file_profile field from auth.yaml
# caused a rename-trap: after renaming the R2 directory, the stale
# profile name inside auth.yaml pointed at the pre-rename profile and
# the provider failed to authenticate. Use each.key as the single source
# of truth and let operators rename the R2 directory + reupload if they
# need a different name.
provider "oci" {
  for_each            = local.oci_provider_accounts
  alias               = "account"
  tenancy_ocid        = try(local.oracle_auth_from_module[each.key].tenancy_ocid, null)
  region              = try(local.oracle_auth_from_module[each.key].region, null)
  config_file_profile = each.key
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
  talos_version                        = var.talos_version
  talos_image_source_uri               = try(var.talos_image_source_uris[each.key], null)
  talos_qcow2_local_path               = var.talos_qcow2_local_path
  force_image_generation               = var.force_image_generation
  shared_patches_dir                   = "${path.module}/../../shared/patches"
  omni_siderolink_url                  = var.omni_siderolink_url
  force_reinstall_generation           = var.force_reinstall_generation
}
