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

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. Module reads use this; writes go directly to R2."
}

variable "talos_image_source_uris" {
  type        = map(string)
  default     = {}
  description = "Per-account (account_key → public HTTPS URL) pre-staged Talos QCOW2 URLs. Operator-pinned URLs — e.g. a shared community bucket — that skip the upload machinery entirely. Takes precedence over talos_qcow2_local_path for the account."
}

variable "talos_qcow2_local_path" {
  type        = string
  default     = null
  description = "Local filesystem path to a pre-downloaded Talos oracle-arm64 QCOW2. When set, each oracle account (for which talos_image_source_uris has no entry) creates a per-account public-read Object Storage bucket and uploads the file. CI populates this from tofu-layer.yml's download step; shared across all OCI accounts since the schematic+version is global."
}

variable "per_node_force_recreate_generation" {
  type        = map(number)
  default     = {}
  description = "Per-OCI-node-key force-recreate generation. Bump a key's value to destroy+create that single instance on next apply — needed when OCI's UpdateInstance accepted a launch_options change but didn't actually rebuild the VNIC."
}

variable "extra_cert_sans" {
  type        = list(string)
  default     = []
  description = "Extra cert SANs included in every OCI node's user_data. Required because OCI's public IPv4 is NAT'd (not on-NIC) so Talos won't auto-discover it for the API serving cert. Layer 03's talos_machine_configuration_apply connects by IP and fails TLS verification without these. Set to the DNS names that layer 03 publishes for OCI CPs (e.g. cp-3.<zone>)."
}
