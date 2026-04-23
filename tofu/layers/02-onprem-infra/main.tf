# tofu/layers/02-onprem-infra/main.tf
locals {
  location_node_maps = [
    for location_key, location in var.onprem_locations : {
      for node_key, node in location.nodes : "${location_key}-${node_key}" => {
        location_key = location_key
        node_key     = node_key
        location     = location
        node         = node
      }
    }
  ]

  flattened_nodes = length(local.location_node_maps) > 0 ? merge(local.location_node_maps...) : {}
}
