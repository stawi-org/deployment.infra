variable "name" {
  type        = string
  description = "Hostname for the Omni host VPS, e.g. cluster-omni-contabo."
}

variable "contabo_product_id" {
  type        = string
  default     = "V47" # VPS-S, 1 CPU/8GB; sufficient for single-instance Omni + dex + cloudflared
  description = "Contabo product ID for the omni-host VPS shape."
}

variable "contabo_image_id" {
  type        = string
  description = "Contabo image ID for Ubuntu 24.04 LTS Minimal. Resolve via the Contabo API."
}

variable "contabo_region" {
  type    = string
  default = "EU"
}

variable "omni_version" { type = string }
variable "dex_version" { type = string }
variable "cloudflared_version" { type = string }

variable "omni_account_name" {
  type        = string
  description = "Top-level Omni account name (e.g. \"stawi\")."
}

variable "siderolink_api_advertised_host" {
  type        = string
  description = "Public hostname Omni advertises in node siderolink cmdlines, e.g. cp.antinvestor.com."
}

variable "siderolink_wireguard_advertised_endpoint" {
  type        = string
  description = "host:port nodes dial for the SideroLink WireGuard mesh. Cloudflare Tunnel cannot proxy UDP, so this MUST be a gray-cloud DNS name (or raw IP) that resolves directly to the VPS public IP. Example: cpd.antinvestor.com:50180."
}

variable "extra_dns_aliases" {
  type        = list(string)
  default     = []
  description = "Extra hostnames the Omni cert/SAN should cover, e.g. [\"cp.stawi.org\"]."
}

variable "github_oidc_client_id" {
  type        = string
  sensitive   = true
  description = "GitHub App client ID brokered via Dex into Omni."
}

variable "github_oidc_client_secret" {
  type      = string
  sensitive = true
}

variable "github_oidc_allowed_orgs" {
  type    = list(string)
  default = ["stawi-org"]
}

variable "cloudflare_tunnel_token" {
  type        = string
  sensitive   = true
  description = "Token for the pre-created CF Tunnel that fronts cp.antinvestor.com / cp.stawi.org."
}

variable "r2_endpoint" { type = string }

variable "r2_backup_access_key_id" {
  type      = string
  sensitive = true
}

variable "r2_backup_secret_access_key" {
  type      = string
  sensitive = true
}

variable "r2_backup_bucket" {
  type    = string
  default = "cluster-tofu-state"
}

variable "r2_backup_prefix" {
  type    = string
  default = "production/omni-backups/"
}
