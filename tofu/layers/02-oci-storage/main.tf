# tofu/layers/02-oci-storage/main.tf
#
# Reads bwire OCI auth from R2-backed inventory and stands up the
# OCI provider alias used by image-registry.tf + oci-operator-csk.tf.
# Single-tenancy layer (bwire only) — no per-account for_each.

locals {
  account_key = "bwire"
}

# node-state: R2-backed inventory read. Plaintext oracle auth.yaml
# (encryption is reserved for contabo's OAuth secrets).
module "bwire_account_state" {
  source              = "../../modules/node-state"
  provider_name       = "oracle"
  account             = local.account_key
  age_recipients      = split(",", var.age_recipients)
  local_inventory_dir = var.local_inventory_dir
}

locals {
  bwire_auth = try(module.bwire_account_state.auth.auth, null)
}

# Each OCI provider uses SecurityToken auth via the WIF profile that
# configure-oci-wif.sh sets up under ~/.oci/config. config_file_profile
# = "bwire" matches the R2 account directory name (the single source of
# truth for profile naming) — see modules/node-state/main.tf and the
# memory note "OCI provider auth".
provider "oci" {
  alias               = "bwire"
  tenancy_ocid        = try(local.bwire_auth.tenancy_ocid, null)
  region              = try(local.bwire_auth.region, null)
  config_file_profile = local.account_key
  auth                = try(local.bwire_auth.auth_method, "SecurityToken")
}

# AWS provider points at Cloudflare R2 — required because node-state
# declares aws as required_providers (for the R2-backed nodes-writer
# path that this layer doesn't currently use). Tofu init still needs
# it configured.
provider "aws" {
  region                      = "auto"
  s3_use_path_style           = true
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_region_validation      = true
  skip_requesting_account_id  = true
  endpoints {
    s3 = "https://${var.r2_account_id}.r2.cloudflarestorage.com"
  }
}

# Effective bwire context — a single-element analogue of
# 02-oracle-infra's local.oci_accounts_effective so the copied
# image-registry.tf + oci-operator-csk.tf bodies need only their
# is_bwire / var.account_key references rewritten, not their
# data-source / namespace lookups.
locals {
  bwire_compartment_ocid = try(local.bwire_auth.compartment_ocid, "")
  bwire_tenancy_ocid     = try(local.bwire_auth.tenancy_ocid, "")
  bwire_region           = try(local.bwire_auth.region, "")
}
