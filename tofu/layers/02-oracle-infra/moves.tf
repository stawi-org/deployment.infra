# tofu/layers/02-oracle-infra/moves.tf
#
# Account rename: stawi-bwire → bwire. Node key follows:
# oci-stawi-bwire-node-1 → oci-bwire-node-1. No OCI instance
# replacement happens — the moved{} blocks only remap tofu state
# addresses; compute/image/network state stays pinned to the same
# provider IDs.

# --- Outer module key rename (account) ------------------------------

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

# --- Inner per-node for_each rename ---------------------------------
#
# After the outer rename, state is at module.oracle_account["bwire"]
# with each for_each-over-nodes key still using the old node_key.
# Remap each resource that iterates per-node to the new key.

moved {
  from = module.oracle_account["bwire"].module.node["oci-stawi-bwire-node-1"]
  to   = module.oracle_account["bwire"].module.node["oci-bwire-node-1"]
}
moved {
  from = module.oracle_account["bwire"].tls_private_key.bastion["oci-stawi-bwire-node-1"]
  to   = module.oracle_account["bwire"].tls_private_key.bastion["oci-bwire-node-1"]
}
moved {
  from = module.oracle_account["bwire"].oci_bastion_session.node["oci-stawi-bwire-node-1"]
  to   = module.oracle_account["bwire"].oci_bastion_session.node["oci-bwire-node-1"]
}
