variable "r2_account_id" {
  type        = string
  description = "Cloudflare R2 account ID — feeds the S3 endpoint URL for backend + AWS provider."
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with permissions: Zone:Read, DNS:Edit on antinvestor.com + stawi.org, Account:Cloudflare Tunnel:Edit."
}

variable "cloudflare_account_id" {
  type        = string
  description = "Cloudflare account ID owning the Zero Trust org and DNS zones."
}

variable "cloudflare_zone_id_antinvestor" {
  type        = string
  description = "Cloudflare zone ID for antinvestor.com."
}

variable "cloudflare_zone_id_stawi" {
  type        = string
  description = "Cloudflare zone ID for stawi.org."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  description = "SSH keys allowed during cloud-init bootstrap and break-glass via Contabo console."
}

variable "contabo_ubuntu_24_04_image_id" {
  type        = string
  description = "Contabo image ID for Ubuntu 24.04 LTS Minimal. Look up via Contabo API; pin here for reproducibility."
}

variable "github_oidc_client_id" {
  type      = string
  sensitive = true
}

variable "github_oidc_client_secret" {
  type      = string
  sensitive = true
}

variable "omni_version" {
  type = string
}

variable "dex_version" {
  type = string
}

variable "cloudflared_version" {
  type = string
}

variable "etcd_backup_r2_access_key_id" {
  type      = string
  sensitive = true
}

variable "etcd_backup_r2_secret_access_key" {
  type      = string
  sensitive = true
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "sops_age_key" {
  type      = string
  sensitive = true
}
