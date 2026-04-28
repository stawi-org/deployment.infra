# tofu/layers/02-onprem-infra/variables.tf
variable "account_key" {
  type        = string
  description = "On-prem account key this layer instance manages. Each on-prem account gets its own state file (production/02-onprem-infra-<account_key>.tfstate); the workflow runs accounts as a fail-fast=false matrix so one account's failure can't block the others. Must be a member of `onprem:` in tofu/shared/accounts.yaml."

  validation {
    condition     = contains(yamldecode(file("${path.module}/../../shared/accounts.yaml")).onprem, var.account_key)
    error_message = "account_key must be listed under `onprem:` in tofu/shared/accounts.yaml. A typo here would silently produce an empty layer; failing plan is the safer default."
  }
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
