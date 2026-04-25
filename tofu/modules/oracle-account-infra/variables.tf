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
variable "force_image_generation" {
  type        = number
  default     = 0
  description = "Bump to force a new Oracle Talos custom image even when the Talos version is unchanged."
}
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

variable "per_node_force_recreate_generation" {
  type        = map(number)
  default     = {}
  description = "Per-node-key force-recreate generation counter. Bumping a key's value forces destroy+create of that single OCI instance — needed when OCI's UpdateInstance accepts a launch_options change in-place but doesn't actually rebuild the VNIC. Keys not present default to 0 (no recreate)."
}
