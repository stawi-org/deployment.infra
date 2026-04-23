# tofu/modules/node-contabo/variables.tf
variable "name" {
  type        = string
  description = "Node name, e.g. kubernetes-controlplane-api-1"
}

variable "role" {
  type        = string
  description = "controlplane | worker"
  validation {
    condition     = contains(["controlplane", "worker"], var.role)
    error_message = "role must be 'controlplane' or 'worker'."
  }
}

variable "product_id" {
  type        = string
  description = "Contabo product ID (e.g. V94)."
}

variable "region" {
  type    = string
  default = "EU"
}

variable "image_id" {
  type        = string
  description = "Contabo custom image ID (Talos image)."
}

# Contabo API credentials — used by null_resource.ensure_image to call
# POST /v1/compute/instances/{id}/actions/reinstall directly when the
# configured image_id drifts from the live instance's imageId. The
# contabo/contabo provider's own image_id update silently PATCHes the
# attribute without triggering a real reinstall, which leaves the
# instance running the previous Talos version while tofu state claims
# the new one — a production-grade trap. See null_resource.ensure_image
# in main.tf for the reinstall-enforcement logic.
variable "contabo_client_id" {
  type        = string
  description = "Contabo OAuth client_id."
  sensitive   = true
}

variable "contabo_client_secret" {
  type        = string
  description = "Contabo OAuth client_secret."
  sensitive   = true
}

variable "contabo_api_user" {
  type        = string
  description = "Contabo API username (email)."
  sensitive   = true
}

variable "contabo_api_password" {
  type        = string
  description = "Contabo API password."
  sensitive   = true
}

variable "force_reinstall_generation" {
  type    = number
  default = 0
  description = <<-EOT
    Bump this to force a disk-wipe reinstall of this instance on the
    next apply. Normally 0 (no reinstall). Change only when:
      - initial onboarding of an instance whose disk has the wrong OS
      - disaster recovery (e.g. etcd corruption on this node)
      - operator explicitly wants a clean Talos install

    For normal Talos version changes, DO NOT bump this — use the
    talos-upgrade flow instead (in-place `talosctl upgrade`, which
    preserves etcd and data). Bumping this wipes the disk.
  EOT
}

