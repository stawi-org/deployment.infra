# tofu/layers/01-contabo-infra/nodes.tf
module "nodes" {
  for_each = var.controlplane_nodes
  source   = "../../modules/node-contabo"

  name       = each.key
  role       = "controlplane"
  product_id = each.value.product_id
  region     = each.value.region
  image_id   = contabo_image.talos.id

  # Used by null_resource.ensure_image in the module to call the
  # Contabo reinstall PUT directly (the contabo provider's own
  # update-in-place path doesn't actually re-image the disk; see
  # the module comment in modules/node-contabo/main.tf).
  contabo_client_id     = var.contabo_client_id
  contabo_client_secret = var.contabo_client_secret
  contabo_api_user      = var.contabo_api_user
  contabo_api_password  = var.contabo_api_password

  # Pass-through. Bump at the layer-01 level (TF_VAR_force_reinstall_generation
  # or terraform.tfvars) to force a cluster-wide disk-wipe reinstall.
  force_reinstall_generation = var.force_reinstall_generation
}
