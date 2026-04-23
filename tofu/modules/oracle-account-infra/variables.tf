# tofu/modules/oracle-account-infra/variables.tf
variable "account_key" { type = string }
variable "compartment_ocid" { type = string }
variable "region" { type = string }
variable "vcn_cidr" { type = string }
variable "enable_ipv6" {
  type        = bool
  default     = true
  description = "Enable Oracle-assigned IPv6 on the VCN, subnet, and worker VNICs."
}

variable "nodes" {
  type = map(object({
    role        = optional(string, "worker")
    shape       = string
    ocpus       = number
    memory_gb   = number
    labels      = optional(map(string), {})
    annotations = optional(map(string), {})
  }))
  validation {
    condition = alltrue([
      for _, node in var.nodes : contains(["controlplane", "worker"], node.role)
    ])
    error_message = "OCI node role must be 'controlplane' or 'worker'."
  }
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Labels applied to every node generated for this OCI account."
}

variable "annotations" {
  type        = map(string)
  default     = {}
  description = "Annotations applied to every node generated for this OCI account."
}

variable "cluster_name" { type = string }
variable "cluster_endpoint" { type = string }
variable "talos_version" { type = string }
variable "kubernetes_version" { type = string }
variable "machine_secrets" {
  type      = any
  sensitive = true
}
variable "shared_patches_dir" { type = string }

variable "bastion_client_cidr_block_allow_list" {
  type        = list(string)
  description = "CIDR ranges allowed to open OCI Bastion sessions for this account. Defaults to 0.0.0.0/0 (session still requires SSH key auth). Override with operator/CI-runner IP ranges for defense in depth."
  default     = ["0.0.0.0/0"]
}
