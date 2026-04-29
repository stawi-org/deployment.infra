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
    # 0-based index into the tenancy's availability_domains list (as
    # returned by OCI's identity API, stable per tenancy and ordered by
    # AD ordinal). Default 0 = "first AD" — works in every region
    # (including single-AD regions where it's the only option). AD-2
    # and AD-3 are typically less contested for A1.Flex Always Free in
    # multi-AD regions, but some Always Free tenancies appear to only
    # have IAM/instance-launch access to AD-1 — defaulting to 0 makes
    # the first-time onboard succeed across the broadest range of
    # tenancies. Existing instances with their AD pinned in tfstate
    # are protected by lifecycle.ignore_changes — they don't migrate
    # when this default changes. Operators can set 1 or 2 explicitly
    # to spread off AD-1 once they've confirmed multi-AD access.
    availability_domain_index = optional(number, 0)
  }))
  validation {
    condition = alltrue([
      for _, node in var.nodes : contains(["controlplane", "worker"], node.role)
    ])
    error_message = "OCI node role must be 'controlplane' or 'worker'."
  }
  validation {
    condition = alltrue([
      for _, node in var.nodes : node.availability_domain_index >= 0
    ])
    error_message = "availability_domain_index must be >= 0 (0-based index into the tenancy's availability_domains list)."
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

variable "talos_version" { type = string }
variable "force_image_generation" {
  type        = number
  default     = 11
  description = "Bump to force a new Oracle Talos custom image even when the Talos version is unchanged."
}
variable "shared_patches_dir" { type = string }

variable "bastion_client_cidr_block_allow_list" {
  type        = list(string)
  description = "CIDR ranges allowed to open OCI Bastion sessions for this account. Defaults to 0.0.0.0/0 (session still requires SSH key auth). Override with operator/CI-runner IP ranges for defense in depth."
  default     = ["0.0.0.0/0"]
}

variable "talos_image_source_uri" {
  type        = string
  default     = null
  description = "Optional public HTTPS URL of a pre-staged Talos QCOW2 (e.g. an OCI Object Storage PAR or public bucket). When set, OCI imports from this URL — letting operators host one stable image and reuse it across resets/regions. Takes precedence over talos_qcow2_local_path (no upload happens). When null AND talos_qcow2_local_path is null, falls back to data.talos_image_factory_urls.this.urls.disk_image (which OCI CreateImage will 400 — external URLs are not supported)."
}

variable "talos_qcow2_local_path" {
  type        = string
  default     = null
  description = "Local filesystem path to a pre-downloaded Talos oracle-arm64 QCOW2. When set (and talos_image_source_uri is empty), the module creates a per-account public-read Object Storage bucket and uploads the file, then points CreateImage at the resulting objectstorage.<region>.oraclecloud.com URL. The workflow populates this by downloading from factory.talos.dev once per plan."
}

variable "per_node_reinstall_request_hash" {
  type        = map(string)
  default     = {}
  description = "Per-node-key SHA1 of the latest applicable reinstall-request file from .github/reconstruction/, or \"\" if none. Computed by layer 02's reconstruction.tf — drives terraform_data.reinstall_marker.triggers_replace and (via replace_triggered_by) destroy+create of the OCI instance for in-scope nodes."
}

variable "omni_siderolink_url" {
  type        = string
  default     = ""
  description = "Full siderolink URL injected into the boot cmdline, e.g. https://cp.antinvestor.com?jointoken=<token>. Empty string disables (transitional during the migration; non-empty after Phase A lands)."
}
