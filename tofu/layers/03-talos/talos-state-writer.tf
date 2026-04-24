# tofu/layers/03-talos/talos-state-writer.tf
#
# Writes talos-state.yaml per provider/account with the last-applied version
# and config hash. Depends on the apply succeeding so we never record a
# version that didn't actually land.

locals {
  # Hash of the rendered machine_configuration per node.
  config_hash_by_node = {
    for k, node in local.all_nodes_from_state :
    k => sha256(try(
      data.talos_machine_configuration.cp[k].machine_configuration,
      data.talos_machine_configuration.worker[k].machine_configuration,
    ))
  }
}

module "contabo_talos_state_writer" {
  for_each            = toset(local.accounts_manifest.contabo)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "contabo"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_talos_state = true
  talos_state_content = {
    provider = "contabo"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
      node_key => {
        last_applied_version = var.talos_version
        last_applied_at      = timestamp()
        last_applied_run_id  = var.ci_run_id
        config_hash          = local.config_hash_by_node[node_key]
      }
      if try(node.provider, "") == "contabo" && try(node.account, "") == each.key
    }
  }

  depends_on = [
    talos_machine_configuration_apply.cp,
    talos_machine_configuration_apply.worker_contabo,
  ]
}

module "oracle_talos_state_writer" {
  for_each            = toset(local.accounts_manifest.oracle)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "oracle"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_talos_state = true
  talos_state_content = {
    provider = "oracle"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
      node_key => {
        last_applied_version = var.talos_version
        last_applied_at      = timestamp()
        last_applied_run_id  = var.ci_run_id
        config_hash          = local.config_hash_by_node[node_key]
      }
      if try(node.provider, "") == "oracle" && try(node.account, "") == each.key
    }
  }

  # Oracle CPs go through talos_machine_configuration_apply.cp now that
  # the VCN has a public subnet and CI can reach them directly. No
  # separate .oci resource to depend on — .cp already iterates over
  # every controlplane_node regardless of provider.
  depends_on = [talos_machine_configuration_apply.cp]
}

module "onprem_talos_state_writer" {
  for_each            = toset(local.accounts_manifest.onprem)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "onprem"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_talos_state = true
  talos_state_content = {
    provider = "onprem"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
      node_key => {
        last_applied_version = var.talos_version
        last_applied_at      = timestamp()
        last_applied_run_id  = var.ci_run_id
        config_hash          = local.config_hash_by_node[node_key]
      }
      if try(node.provider, "") == "onprem" && try(node.account, "") == each.key
    }
  }

  depends_on = [
    talos_machine_configuration_apply.cp,
    talos_machine_configuration_apply.worker_contabo,
  ]
}
