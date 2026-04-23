# tofu/layers/01-contabo-infra/imports.tf
#
# Import the 3 existing Contabo control-plane instances into layer 01 state.
# After import, changing `image_id` on `contabo_instance` triggers the Contabo
# provider's update-with-reinstall flow: instance ID and IP are preserved, storage
# is wiped, and the instance boots into the new image (Talos v1.13.0-rc.0).
#
# Leaving this block in place after first apply is idempotent — OpenTofu skips
# the import when the resource is already in state.

locals {
  existing_contabo_instance_ids = {
    "kubernetes-controlplane-api-1" = "202727783"
    "kubernetes-controlplane-api-2" = "202727782"
    "kubernetes-controlplane-api-3" = "202727781"
  }
}

import {
  for_each = local.existing_contabo_instance_ids
  to       = module.nodes[each.key].contabo_instance.this
  id       = each.value
}
