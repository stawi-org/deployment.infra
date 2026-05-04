# tofu/layers/01-contabo-infra/moves.tf
#
# Two rename generations layered via moved{} chains. Each block
# survives indefinitely as a no-op once its "from" address is no
# longer in state — they're kept as the audit trail.
#
#   Gen 1: kubernetes-controlplane-api-N → contabo-stawi-contabo-node-N
#          (<provider>-<account>-node-N convention).
#   Gen 2: stawi-contabo → bwire  (account rename).
#          Node keys become contabo-bwire-node-N.
#
# Contabo's display_name is NOT ForceNew, so tofu will update it on
# Contabo's side in-place on the next apply — no instance replacement.

# --- Gen 1: node-key rename ------------------------------------------

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

# --- Gen 2: account rename ------------------------------------------

moved {
  from = module.contabo_account_state["stawi-contabo"]
  to   = module.contabo_account_state["bwire"]
}
moved {
  from = module.contabo_nodes_writer["stawi-contabo"]
  to   = module.contabo_nodes_writer["bwire"]
}
moved {
  from = contabo_image.talos["stawi-contabo"]
  to   = contabo_image.talos["bwire"]
}
moved {
  from = module.nodes["contabo-stawi-contabo-node-1"]
  to   = module.nodes["contabo-bwire-node-1"]
}
moved {
  from = module.nodes["contabo-stawi-contabo-node-2"]
  to   = module.nodes["contabo-bwire-node-2"]
}
moved {
  from = module.nodes["contabo-stawi-contabo-node-3"]
  to   = module.nodes["contabo-bwire-node-3"]
}

# --- Reconstruction-mechanism cleanup --------------------------------
# Drop legacy reinstall-trigger terraform_data from state without
# destroying anything Contabo-side. The reinstall flow is now
# image-drift-driven (contabo_image UUID change → ensure-image.sh
# detects the diff and PUTs the reinstall PUT).
removed {
  from = terraform_data.image_generation
  lifecycle {
    destroy = false
  }
}

removed {
  from = terraform_data.image_reinstall_marker
  lifecycle {
    destroy = false
  }
}

# --- bwire-3 leaves the cluster pool ---------------------------------
# VPS 202727781 was promoted to omni-host (adopted by 00-omni-server's
# omni-host-contabo module). Remove from this layer's tfstate without
# destroying the underlying resource — Contabo's destroy path is
# unimplemented in the provider anyway (tries DELETE, gets HTTP error),
# and a Contabo VPS reinstall in place is how the omni-host gets its
# Ubuntu image. Pairs with the bwire-3 entry already removed from
# tofu/shared/bootstrap/contabo-instance-ids.yaml.
removed {
  from = module.nodes["contabo-bwire-node-3"]
  lifecycle {
    destroy = false
  }
}
