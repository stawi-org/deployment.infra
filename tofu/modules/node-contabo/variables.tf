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

variable "account_key" {
  type        = string
  description = "Contabo account key from inventory."
}

variable "region" {
  type    = string
  default = "EU"
}

variable "image_id" {
  type        = string
  description = "Contabo custom image ID (Talos image)."
}

variable "force_reinstall_generation" {
  type        = number
  default     = 1
  description = <<-EOT
    Operator-controlled bump that forces a VPS reinstall without
    requiring a schematic change. Bumping the value (e.g. 1 → 2)
    re-keys the null_resource.ensure_image trigger map so the
    resource is replaced; on apply, ensure-image.sh runs with
    FORCE_REINSTALL=1 and PUTs unconditionally regardless of the
    current imageId.

    Use to recover stuck nodes (Talos in a bad state, kernel-cmdline
    refresh needed, lost siderolink registration) without going
    through the heavyweight schematic-bump → regen-talos-images →
    merged-PR loop. Routine reinstalls driven by an actual image
    change still happen automatically through the target_image_id
    trigger; this knob is only for "I want a reinstall NOW".

    Bump generation history:
      1 — initial.
  EOT
  validation {
    condition     = var.force_reinstall_generation >= 1
    error_message = "force_reinstall_generation must be >= 1."
  }
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Additional Kubernetes node labels for this Contabo node."
}

variable "annotations" {
  type        = map(string)
  default     = {}
  description = "Additional Kubernetes node annotations for this Contabo node."
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
