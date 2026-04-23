variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID. Used to construct the S3-compatible endpoint for cross-layer terraform_remote_state reads."
}

variable "talos_version" { type = string }
variable "kubernetes_version" { type = string }
variable "flux_version" { type = string }

variable "github_repo_owner" {
  type    = string
  default = "antinvestor"
}

variable "github_repo_name" {
  type    = string
  default = "deployments"
}

variable "github_repo_branch" {
  type    = string
  default = "main"
}

# GitHub App credentials consumed by source-controller to authenticate git
# against the repo. Managed by tofu, materialised as the `ghapp-secret`
# Secret in flux-system and referenced by FluxInstance.spec.sync.pullSecret.
variable "github_app_id" {
  type      = string
  sensitive = true
}

variable "github_app_installation_id" {
  type      = string
  sensitive = true
}

variable "github_app_private_key" {
  type      = string
  sensitive = true
}

variable "sops_age_key" {
  type      = string
  sensitive = true
}

variable "etcd_backup_r2_access_key_id" {
  type      = string
  sensitive = true
}

variable "etcd_backup_r2_secret_access_key" {
  type      = string
  sensitive = true
}
