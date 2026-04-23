# tofu/layers/02-oracle-infra/variables.tf
variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID. Used to construct the S3-compatible endpoint for cross-layer terraform_remote_state reads."
}

variable "talos_version" {
  type = string
}

variable "force_image_generation" {
  type        = number
  default     = 0
  description = "Bump to force a new Oracle Talos custom image even when talos_version is unchanged."
}

variable "kubernetes_version" {
  type = string
}

variable "flux_version" {
  type = string
}

variable "cluster_name" {
  type    = string
  default = "antinvestor-cluster"
}

variable "cluster_endpoint" {
  type        = string
  description = "Stable URL of the Talos/K8s API — use the FIRST Contabo CP public IPv4 until a VIP or LB exists."
}

variable "oci_accounts" {
  type = map(object({
    tenancy_ocid                         = string
    compartment_ocid                     = string
    region                               = string
    vcn_cidr                             = string
    enable_ipv6                          = optional(bool, true)
    bastion_client_cidr_block_allow_list = optional(list(string), ["0.0.0.0/0"])
    labels                               = optional(map(string), {})
    annotations                          = optional(map(string), {})
    nodes = map(object({
      role        = optional(string, "worker")
      shape       = string
      ocpus       = number
      memory_gb   = number
      labels      = optional(map(string), {})
      annotations = optional(map(string), {})
    }))
  }))
  description = "One entry per OCI tenancy/account."
  # Fast in-HCL guard for identical CIDRs. The workflow also runs
  # scripts/check-cidr-overlap.py for exhaustive cross-account overlap checks.
  validation {
    condition = length([
      for pair in setproduct(keys(var.oci_accounts), keys(var.oci_accounts)) :
      pair if pair[0] < pair[1] && (
        cidrhost(var.oci_accounts[pair[0]].vcn_cidr, 0) == cidrhost(var.oci_accounts[pair[1]].vcn_cidr, 0)
        ||
        cidrnetmask(var.oci_accounts[pair[0]].vcn_cidr) == cidrnetmask(var.oci_accounts[pair[1]].vcn_cidr)
        && cidrhost(var.oci_accounts[pair[0]].vcn_cidr, 0) == cidrhost(var.oci_accounts[pair[1]].vcn_cidr, 0)
      )
    ]) == 0
    error_message = "All oci_accounts must have distinct vcn_cidr values; CI also runs scripts/check-cidr-overlap.py for exhaustive overlap detection."
  }

  validation {
    condition = alltrue(flatten([
      for account_key, account in var.oci_accounts : [
        for node_key, node in account.nodes :
        length("${account_key}-${node_key}") <= 63
        && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", "${account_key}-${node_key}"))
        && contains(["controlplane", "worker"], node.role)
      ]
    ]))
    error_message = "OCI account and node keys must combine into valid RFC 1123 node names, for example stawi-a-wk-1."
  }
}

variable "retained_oci_accounts" {
  type = map(object({
    tenancy_ocid                         = string
    compartment_ocid                     = string
    region                               = string
    vcn_cidr                             = string
    enable_ipv6                          = optional(bool, true)
    bastion_client_cidr_block_allow_list = optional(list(string), ["0.0.0.0/0"])
    labels                               = optional(map(string), {})
    annotations                          = optional(map(string), {})
    nodes = map(object({
      role        = optional(string, "worker")
      shape       = string
      ocpus       = number
      memory_gb   = number
      labels      = optional(map(string), {})
      annotations = optional(map(string), {})
    }))
  }))
  default     = {}
  description = <<-EOT
    OCI accounts whose provider profiles must remain configured for one extra
    apply after removing them from oci_accounts. This lets OpenTofu destroy
    resources before the matching provider instance disappears.
  EOT

  validation {
    condition = alltrue(flatten([
      for account_key, account in var.retained_oci_accounts : [
        for node_key, node in account.nodes :
        length("${account_key}-${node_key}") <= 63
        && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", "${account_key}-${node_key}"))
        && contains(["controlplane", "worker"], node.role)
      ]
    ]))
    error_message = "Retained OCI account and node keys must combine into valid RFC 1123 node names, for example stawi-a-wk-1."
  }
}
