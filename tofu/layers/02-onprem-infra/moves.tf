# tofu/layers/02-onprem-infra/moves.tf
#
# Account rename: savannah-hq → tindase. Node key follows the
# <provider>-<account>-node-N convention:
# onprem-savannah-hq-node-1 → onprem-tindase-node-1. On-prem has no
# cloud resources, only the two node-state module instances, so the
# blast radius of the rename is just a state-entry remap.

moved {
  from = module.onprem_account_state["savannah-hq"]
  to   = module.onprem_account_state["tindase"]
}
moved {
  from = module.onprem_nodes_writer["savannah-hq"]
  to   = module.onprem_nodes_writer["tindase"]
}
