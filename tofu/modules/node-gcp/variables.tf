# tofu/modules/node-gcp/variables.tf
variable "name" {
  type        = string
  description = "Canonical node name, e.g. gcp-stawi-prod-node-1"
}

variable "role" {
  type = string
  validation {
    condition     = var.role == "worker"
    error_message = "GCP nodes must have role 'worker' in v1."
  }
}

variable "machine_type" { type = string }
variable "zone" { type = string }
variable "boot_disk_gb" {
  type = number
  validation {
    condition     = var.boot_disk_gb >= 50
    error_message = "boot_disk_gb must be >= 50 (Talos image floor)."
  }
}
variable "preemptible" {
  type        = bool
  default     = true
  description = "When true, use GCE Spot (provisioning_model=SPOT)."
}
variable "image" {
  type        = string
  description = "GCE image self_link or family path."
}
variable "network" { type = string }
variable "subnetwork" { type = string }
variable "account_key" { type = string }
variable "region" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}
variable "annotations" {
  type    = map(string)
  default = {}
}
variable "force_reinstall_generation" {
  type        = number
  default     = 1
  description = <<-EOT
    Operator-controlled bump that forces a destroy+create of the GCE
    instance. Bumping the value (e.g. 1 → 2) changes
    terraform_data.force_reinstall → fires replace_triggered_by →
    instance is recreated, gets a fresh boot, re-registers with Omni
    via siderolink-api.

    Mirrors var.force_reinstall_generation in node-oracle / node-contabo
    so a single bump rolls cluster nodes without a schematic round-trip.
  EOT
  validation {
    condition     = var.force_reinstall_generation >= 1
    error_message = "force_reinstall_generation must be >= 1."
  }
}
