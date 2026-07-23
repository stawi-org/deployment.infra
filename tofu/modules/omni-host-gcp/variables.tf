variable "name" {
  type        = string
  description = "Hostname / instance name for the Omni host, e.g. gcp-stawi-timber-omni."
}

variable "project_id" {
  type        = string
  description = "GCP project id (e.g. stawi-timber's project)."
}

variable "region" {
  type        = string
  description = "GCP region. Always Free e2-micro is only free in us-west1, us-central1, us-east1."
  default     = "us-central1"
}

variable "zone" {
  type        = string
  description = "GCP zone for the instance."
  default     = "us-central1-a"
}

variable "machine_type" {
  type        = string
  description = <<-EOT
    GCE machine type. Always Free eligible: e2-micro (1 GiB RAM) in select US
    regions. Omni+Dex+nginx is tight on 1 GiB — cloud-init adds 2 GiB swap.
    Prefer e2-small (2 GiB) or e2-medium if free-tier is not required.
  EOT
  default     = "e2-micro"
}

variable "boot_disk_gb" {
  type        = number
  description = "Boot disk size (GB). Always Free includes 30 GB-months standard PD."
  default     = 30
}

variable "vpc_cidr" {
  type        = string
  description = "Dedicated VPC CIDR for the Omni host (isolated from Talos worker VPC)."
  default     = "10.220.0.0/24"
}

variable "omni_version" { type = string }
variable "dex_version" { type = string }
variable "nginx_version" {
  type        = string
  default     = "1.27-alpine"
  description = "Nginx image tag — reverse-proxies cp.<zone> to Omni UI."
}

variable "omni_account_name" {
  type        = string
  description = "Top-level Omni account name (e.g. \"stawi\")."
}

variable "omni_account_id" {
  type        = string
  description = "Stable Omni account UUID (layer random_uuid)."
}

variable "siderolink_api_advertised_host" {
  type        = string
  description = "Browser-facing Omni hostname (orange-cloud Cloudflare)."
}

variable "siderolink_wireguard_advertised_host" {
  type        = string
  description = "Talos-facing Omni hostname (gray-cloud direct A)."
}

variable "github_oidc_client_id" {
  type      = string
  sensitive = true
}

variable "github_oidc_client_secret" {
  type      = string
  sensitive = true
}

variable "github_oidc_allowed_orgs" {
  type    = list(string)
  default = ["stawi-org"]
}

variable "cf_dns_api_token" {
  type      = string
  sensitive = true
}

variable "initial_users" {
  type = list(string)
  validation {
    condition     = length(var.initial_users) > 0
    error_message = "At least one initial admin email is required."
  }
}

variable "eula_name" { type = string }
variable "eula_email" { type = string }

variable "etcd_backup_enabled" {
  type    = bool
  default = false
}

variable "dex_omni_client_secret" {
  type      = string
  sensitive = true
}

variable "ssh_authorized_keys" {
  type    = list(string)
  default = []
}

variable "vpn_users" {
  type = map(object({
    public_key = string
  }))
  default = {}
}

variable "r2_account_id" { type = string }
variable "r2_access_key_id" {
  type      = string
  sensitive = true
}
variable "r2_secret_access_key" {
  type      = string
  sensitive = true
}
variable "r2_bucket_name" {
  type    = string
  default = "cluster-tofu-state"
}
variable "r2_backup_prefix" {
  type    = string
  default = "production/omni-backups"
}

variable "labels" {
  type        = map(string)
  default     = {}
  description = "Extra GCE labels (merged with stawi defaults)."
}
