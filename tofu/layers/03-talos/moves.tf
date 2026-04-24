# tofu/layers/03-talos/moves.tf
#
# Rename node_keys in the talos-layer resources that key on
# upstream node outputs. Only api-1 is currently in
# direct_controlplane_nodes (api-2 / api-3 are in talos_apply_skip),
# so only its resources have state entries to migrate. Without these
# moves tofu would destroy+create the apply resource and trigger a
# reboot of api-1.

moved {
  from = terraform_data.cp_config_hash["kubernetes-controlplane-api-1"]
  to   = terraform_data.cp_config_hash["contabo-stawi-contabo-node-1"]
}
moved {
  from = talos_machine_configuration_apply.cp["kubernetes-controlplane-api-1"]
  to   = talos_machine_configuration_apply.cp["contabo-stawi-contabo-node-1"]
}
