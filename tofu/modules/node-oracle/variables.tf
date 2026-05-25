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
variable "force_reinstall_generation" {
  type        = number
  default     = 1
  description = <<-EOT
    Operator-controlled bump that forces a destroy+create of the OCI
    instance regardless of image_id stability. Bumping the value (e.g.
    1 → 2) changes terraform_data.force_reinstall.input → fires the
    replace_triggered_by → instance is recreated, gets a fresh boot,
    re-registers with Omni via siderolink-api.

    Mirrors var.force_reinstall_generation in node-contabo so a
    single bump in both `02-oracle-infra/terraform.tfvars` and
    `01-contabo-infra/terraform.tfvars` rolls every cluster node
    without going through the schematic-bump round-trip.

    Bump generation history:
      1 — initial.
  EOT
  validation {
    condition     = var.force_reinstall_generation >= 1
    error_message = "force_reinstall_generation must be >= 1."
  }
}

variable "boot_volume_size_in_gbs" {
  type        = number
  default     = 180
  description = <<-EOT
    Boot volume size in GB. OCI's always-free tier gives 200 GB total
    block-volume per tenancy. For tenancies hosting multiple instances
    (e.g. bwire shares a cluster node + the omni-host), set
    boot_volume_size_gb per-node in R2 inventory to split the quota
    (e.g. 97 GB each = 194 GB total). The default 180 is for single-
    node tenancies with no other block-volume consumers.

    source_details is in ignore_changes, so changing this value does
    not affect running instances — the new size takes effect only on
    the next reinstall (image change or force_reinstall_generation
    bump). The Talos QCOW2's declared size (47 GB) is the floor.
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
