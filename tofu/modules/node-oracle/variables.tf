# tofu/modules/node-oracle/variables.tf
variable "name" { type = string }
variable "role" {
  type    = string
  default = "worker"
  validation {
    condition     = contains(["controlplane", "worker"], var.role)
    error_message = "OCI node role must be 'controlplane' or 'worker'."
  }
}
variable "shape" { type = string }
variable "ocpus" { type = number }
variable "memory_gb" { type = number }
variable "subnet_id" { type = string }
variable "image_id" { type = string }
variable "compartment_ocid" { type = string }
variable "boot_volume_size_in_gbs" {
  type        = number
  default     = 180
  description = <<-EOT
    Boot volume size in GB. Default 180 stays well under the OCI
    always-free per-tenancy block-volume cap (200 GB total across all
    volumes) with a 20 GB buffer for incidentals (boot-volume
    backups, automatic snapshots, other small volumes the tenancy
    might accumulate) so the tenancy never bills.

    OCI rejects in-place size decreases, so reducing this on an
    existing instance forces destroy+create. The Talos QCOW2's
    declared size (47 GB) is the floor — values below ~50 GB are
    rejected by CreateInstance on A1.Flex.

    Per-tenancy hard ceiling: 195 GB (enforced below). Do not raise
    above that without confirming the tenancy isn't sharing the
    free-tier quota with other resources.
  EOT
  validation {
    condition     = var.boot_volume_size_in_gbs >= 50 && var.boot_volume_size_in_gbs <= 195
    error_message = "boot_volume_size_in_gbs must be between 50 (Talos QCOW2 floor) and 195 (per-tenancy free-tier ceiling)."
  }
}
variable "assign_ipv6" {
  type        = bool
  default     = true
  description = "Assign an IPv6 address from the subnet to the primary worker VNIC."
}
variable "availability_domain" { type = string }
variable "labels" {
  type        = map(string)
  default     = {}
  description = "Additional Kubernetes node labels for this OCI worker."
}
variable "annotations" {
  type        = map(string)
  default     = {}
  description = "Additional Kubernetes node annotations for this OCI worker."
}
variable "bastion_id" { type = string }
variable "account_key" { type = string }
variable "region" { type = string }
