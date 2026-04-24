# tofu/layers/01-contabo-infra/moves.tf
#
# Rename node_keys to the agreed <provider>-<account>-node-N pattern
# without destroy+create. Tofu's moved{} blocks remap the existing
# module instance (and every resource inside it) from the old key to
# the new. Contabo's display_name is NOT ForceNew, so tofu will update
# it on Contabo's side in-place on the next apply.
#
# After the first apply following this commit succeeds, these moved{}
# blocks are no-op forever. They're kept in the repo as the audit
# trail for the rename.

moved {
  from = module.nodes["kubernetes-controlplane-api-1"]
  to   = module.nodes["contabo-stawi-contabo-node-1"]
}
moved {
  from = module.nodes["kubernetes-controlplane-api-2"]
  to   = module.nodes["contabo-stawi-contabo-node-2"]
}
moved {
  from = module.nodes["kubernetes-controlplane-api-3"]
  to   = module.nodes["contabo-stawi-contabo-node-3"]
}
