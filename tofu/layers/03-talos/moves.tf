# tofu/layers/03-talos/moves.tf
#
# Chained renames for resources that for_each over upstream node_keys.
# Only api-1 is currently in direct_controlplane_nodes (api-2 / api-3
# and the OCI CP are in talos_apply_skip), so only its resources have
# state entries to migrate. Without these moves tofu would destroy+
# create the apply resource and trigger a reboot of api-1.
#
#   Gen 1: kubernetes-controlplane-api-1 → contabo-stawi-contabo-node-1
#   Gen 2: contabo-stawi-contabo-node-1   → contabo-bwire-node-1

# --- Gen 1: node-key rename -----------------------------------------

moved {
  from = terraform_data.cp_config_hash["kubernetes-controlplane-api-1"]
  to   = terraform_data.cp_config_hash["contabo-stawi-contabo-node-1"]
}
moved {
  from = talos_machine_configuration_apply.cp["kubernetes-controlplane-api-1"]
  to   = talos_machine_configuration_apply.cp["contabo-stawi-contabo-node-1"]
}

# --- Gen 2: account rename ------------------------------------------

moved {
  from = terraform_data.cp_config_hash["contabo-stawi-contabo-node-1"]
  to   = terraform_data.cp_config_hash["contabo-bwire-node-1"]
}
moved {
  from = talos_machine_configuration_apply.cp["contabo-stawi-contabo-node-1"]
  to   = talos_machine_configuration_apply.cp["contabo-bwire-node-1"]
}
