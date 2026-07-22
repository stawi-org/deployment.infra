# tofu/modules/gcp-account-infra/nodes.tf
#
# GCE workers boot Talos in maintenance mode from the Omni-aware custom
# image (siderolink.api baked into the schematic). Omni pushes machine
# config after SideroLink registration — same model as node-oracle.

module "node" {
  for_each = var.nodes
  source   = "../node-gcp"

  name                       = each.key
  role                       = each.value.role
  machine_type               = each.value.machine_type
  zone                       = each.value.zone
  boot_disk_gb               = each.value.boot_disk_gb
  preemptible                = try(each.value.preemptible, true)
  image                      = local.image_self_link
  network                    = google_compute_network.this.self_link
  subnetwork                 = google_compute_subnetwork.workers.self_link
  account_key                = var.account_key
  region                     = var.region
  labels                     = merge(var.labels, try(each.value.labels, {}))
  annotations                = merge(var.annotations, try(each.value.annotations, {}))
  force_reinstall_generation = var.force_reinstall_generation
}
