# tofu/layers/00-omni-server/moves.tf
#
# omni_host_provider switch: adding count to module.omni_host_oci changes
# its address from module.omni_host_oci to module.omni_host_oci[0].
# This moved{} block migrates existing state so no destroy+create happens
# when var.omni_host_provider remains "oci" (the default).

moved {
  from = module.omni_host_oci
  to   = module.omni_host_oci[0]
}
