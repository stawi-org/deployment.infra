# tofu/layers/03-talos/machine-configs-writer.tf
#
# Per-account machine-configs.yaml writer. Encrypts + uploads to R2.

module "contabo_machine_configs_writer" {
  for_each            = toset(local.accounts_manifest.contabo)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "contabo"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_machine_configs = true
  machine_configs_content = {
    provider = "contabo"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
      node_key => {
        target_talos_version = var.talos_version
        schematic_id         = talos_image_factory_schematic.this.id
        rendered_at          = timestamp()
        rendered_by_run_id   = var.ci_run_id
        machine_type         = node.role
        machine_configuration = try(
          data.talos_machine_configuration.cp[node_key].machine_configuration,
          data.talos_machine_configuration.worker[node_key].machine_configuration,
        )
      }
      if try(node.provider, "") == "contabo" && try(node.account, "") == each.key
    }
  }
}

module "oracle_machine_configs_writer" {
  for_each            = toset(local.accounts_manifest.oracle)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "oracle"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_machine_configs = true
  machine_configs_content = {
    provider = "oracle"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
      node_key => {
        target_talos_version = var.talos_version
        schematic_id         = talos_image_factory_schematic.this.id
        rendered_at          = timestamp()
        rendered_by_run_id   = var.ci_run_id
        machine_type         = node.role
        machine_configuration = try(
          data.talos_machine_configuration.cp[node_key].machine_configuration,
          data.talos_machine_configuration.worker[node_key].machine_configuration,
        )
      }
      if try(node.provider, "") == "oracle" && try(node.account, "") == each.key
    }
  }
}

module "onprem_machine_configs_writer" {
  for_each            = toset(local.accounts_manifest.onprem)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "onprem"
  account             = each.key
  age_recipients      = split(",", var.age_recipients)

  write_machine_configs = true
  machine_configs_content = {
    provider = "onprem"
    account  = each.key
    nodes = {
      for node_key, node in local.all_nodes_from_state :
      node_key => {
        target_talos_version = var.talos_version
        schematic_id         = talos_image_factory_schematic.this.id
        rendered_at          = timestamp()
        rendered_by_run_id   = var.ci_run_id
        machine_type         = node.role
        machine_configuration = try(
          data.talos_machine_configuration.cp[node_key].machine_configuration,
          data.talos_machine_configuration.worker[node_key].machine_configuration,
        )
      }
      if try(node.provider, "") == "onprem" && try(node.account, "") == each.key
    }
  }
}
