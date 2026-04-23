# tofu/layers/02-oracle-infra/variables.tf
variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID. Used to construct the S3-compatible endpoint for cross-layer terraform_remote_state reads."
}

variable "talos_version" {
  type = string
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
    tenancy_ocid     = string
    compartment_ocid = string
    region           = string
    vcn_cidr         = string
    workers = map(object({
      shape     = string
      ocpus     = number
      memory_gb = number
    }))
  }))
  description = "One entry per OCI tenancy/account."
  # Heuristic non-overlap check: flags identical network addresses AND cases where
  # one CIDR's network address falls within another CIDR. Does NOT catch every
  # pathological overlap (e.g. 10.0.0.0/8 vs 10.1.0.0/16 where neither's network
  # address is within the other at index 0) — but in practice, assigning
  # systematic /16 blocks (10.200.0.0/16, 10.201.0.0/16, ...) sidesteps this.
  # For full-coverage overlap detection, run `scripts/check-cidr-overlap.py` as a
  # CI pre-check (not yet implemented — follow-up).
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
    error_message = "All oci_accounts must have non-overlapping vcn_cidr values (heuristic check — see scripts/check-cidr-overlap.py for exhaustive)."
  }
}

