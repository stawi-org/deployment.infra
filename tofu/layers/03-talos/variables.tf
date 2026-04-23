# tofu/layers/03-talos/variables.tf
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
  type = string
}

variable "force_talos_reapply_generation" {
  type        = string
  default     = "1"
  description = "Bump this (1 -> 2) to force all talos_machine_configuration_apply resources to be destroyed + recreated on the next apply. Use when nodes are stuck in a bad state (e.g. kubelet ImagePullBackOff) and need a reboot triggered by tofu. Feeds into terraform_data config-hash inputs and replace_triggered_by fires on change."
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}
