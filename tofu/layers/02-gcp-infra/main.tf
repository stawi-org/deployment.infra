# tofu/layers/02-gcp-infra/main.tf
#
# This layer provisions GCP infrastructure (VPC, firewall, GCE Spot
# instances). It does NOT generate or push Talos machine configs —
# GCP nodes boot in Talos maintenance mode from an Omni-aware custom
# image (siderolink.api is baked into the image schematic; instance
# metadata stays empty). Layer 03 owns cluster-level configuration
# via machine patches, the same flow Contabo + Oracle + onprem use.

locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
  gcp_account_keys  = [var.account_key]
}

# node-state: R2-backed inventory read. Populated initially by
# scripts/seed-inventory.sh / onboard-gcp; kept in sync by this layer's writers.
module "gcp_account_state" {
  for_each            = toset(local.gcp_account_keys)
  source              = "../../modules/node-state"
  provider_name       = "gcp"
  account             = each.key
  local_inventory_dir = var.local_inventory_dir
}

locals {
  gcp_auth_from_module = {
    for k, mod in module.gcp_account_state : k => try(mod.auth.auth, null)
  }
  gcp_nodes_from_module = {
    for k, mod in module.gcp_account_state : k => try(mod.nodes.nodes, {})
  }
  gcp_accounts_effective = {
    for k in local.gcp_account_keys : k => merge(
      try(local.gcp_auth_from_module[k], {}),
      {
        nodes       = local.gcp_nodes_from_module[k]
        labels      = try(module.gcp_account_state[k].nodes.labels, {})
        annotations = try(module.gcp_account_state[k].nodes.annotations, {})
      },
    )
  }
}

provider "google" {
  project = try(local.gcp_auth_from_module[var.account_key].project_id, null)
  region  = try(local.gcp_auth_from_module[var.account_key].region, null)
  # Credentials via GOOGLE_APPLICATION_CREDENTIALS / WIF ADC from CI.
}

module "gcp_account" {
  for_each = local.gcp_accounts_effective
  source   = "../../modules/gcp-account-infra"

  account_key                = each.key
  project_id                 = try(each.value.project_id, "")
  region                     = try(each.value.region, "")
  vpc_cidr                   = try(each.value.vpc_cidr, "10.210.0.0/16")
  nodes                      = try(each.value.nodes, {})
  labels                     = try(each.value.labels, {})
  annotations                = try(each.value.annotations, {})
  local_inventory_dir        = var.local_inventory_dir
  force_reinstall_generation = var.force_reinstall_generation
}
