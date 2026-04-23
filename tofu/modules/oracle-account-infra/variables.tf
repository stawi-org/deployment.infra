# tofu/modules/oracle-account-infra/variables.tf
variable "account_key" { type = string }
variable "compartment_ocid" { type = string }
variable "region" { type = string }
variable "vcn_cidr" { type = string }

variable "workers" {
  type = map(object({
    shape     = string
    ocpus     = number
    memory_gb = number
  }))
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
