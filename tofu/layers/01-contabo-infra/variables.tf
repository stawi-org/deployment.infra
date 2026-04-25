# tofu/layers/01-contabo-infra/variables.tf
variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "flux_version" {
  type = string
}


variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token, Zone:DNS:Edit. Kept in this layer ONLY to destroy the legacy cp_dns records still in its state — the new publishing path lives in layer 03. Remove once layer 01's state is clean of cloudflare_dns_record resources."
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID; used for the S3-compatible AWS provider endpoint."
}

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. Module reads use this; writes go directly to R2."
}
