# tofu/layers/02-oci-storage/variables.tf
variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID. Used to construct the S3-compatible endpoint for the state backend and node-state reads."
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Required by the shared node-state module's sops decryption path even though oracle auth.yaml is plaintext."
}

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. node-state reads from here."
}

variable "oci_operator_user_name" {
  type        = string
  description = "Name of the existing OCI operator user in the bwire tenancy. CSK minted against this user."
  validation {
    condition     = var.oci_operator_user_name != ""
    error_message = "oci_operator_user_name must be set (the existing operator user that owns the shared S3-compat CSK)."
  }
}
