# tofu/layers/02-onprem-infra/variables.tf
variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "flux_version" {
  type = string
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
