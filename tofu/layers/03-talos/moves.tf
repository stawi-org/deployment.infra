# tofu/layers/03-talos/moves.tf
#
# Drop the legacy talos_machine_configuration_apply.cp + cp_config_hash
# resources from state. They were superseded by null_resource.apply_cp_config
# which uses talosctl --insecure (see apply.tf for rationale). Their
# server-side effect — config applied to each node — is preserved on
# disk; deleting state just frees tofu from tracking them.

removed {
  from = talos_machine_configuration_apply.cp
  lifecycle { destroy = false }
}

removed {
  from = talos_machine_configuration_apply.worker_contabo
  lifecycle { destroy = false }
}

removed {
  from = terraform_data.cp_config_hash
  lifecycle { destroy = false }
}

removed {
  from = terraform_data.worker_contabo_config_hash
  lifecycle { destroy = false }
}
