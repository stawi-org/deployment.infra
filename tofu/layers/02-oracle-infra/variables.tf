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
  description = "Per-account (account_key → public HTTPS URL) pre-staged Talos QCOW2 URLs. The workflow uploads the factory image into each account's OCI Object Storage bucket and sets the map via TF_VAR_talos_image_source_uris. OCI's CreateImage rejects external HTTPS source URIs — it only accepts OCI Object Storage URLs. Unset entries fall back to the live factory URL (which will 400 on CreateImage)."
}
