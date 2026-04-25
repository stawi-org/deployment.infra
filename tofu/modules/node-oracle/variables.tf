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
variable "user_data" {
  type        = string
  sensitive   = true
  description = "Base64-encoded Talos machine config."
}
variable "bastion_id" { type = string }
variable "account_key" { type = string }
variable "region" { type = string }
variable "force_recreate_generation" {
  type        = number
  default     = 0
  description = "Bump to force a clean destroy+create of the OCI instance even when no other input changed. Needed when OCI's UpdateInstance accepted a launch_options change but didn't actually rebuild the VNIC, leaving the running instance with the wrong NIC type."
}
