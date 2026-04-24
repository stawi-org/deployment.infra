# tofu/layers/02-oracle-infra/moves.tf
#
# Account rename: stawi-bwire → bwire. Node key follows:
# oci-stawi-bwire-node-1 → oci-bwire-node-1. No OCI instance
# replacement happens — the moved{} blocks only remap tofu state
# addresses; compute/image/network state stays pinned to the same
# provider IDs.

moved {
  from = module.oracle_account_state["stawi-bwire"]
  to   = module.oracle_account_state["bwire"]
}
moved {
  from = module.oracle_nodes_writer["stawi-bwire"]
  to   = module.oracle_nodes_writer["bwire"]
}
moved {
  from = module.oracle_account["stawi-bwire"]
  to   = module.oracle_account["bwire"]
}
moved {
  from = module.oracle_account["bwire"].module.node["oci-stawi-bwire-node-1"]
  to   = module.oracle_account["bwire"].module.node["oci-bwire-node-1"]
}
