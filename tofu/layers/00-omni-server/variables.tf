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

variable "contabo_ubuntu_24_04_image_id" {
  type        = string
  description = "Contabo image ID for Ubuntu 24.04 LTS Minimal. Look up once via the Contabo API and pin in terraform.tfvars; image IDs are stable per Contabo's catalog. Not sensitive — public catalog data."
  default     = ""

  validation {
    condition     = var.contabo_ubuntu_24_04_image_id != ""
    error_message = "Set contabo_ubuntu_24_04_image_id in tofu/layers/00-omni-server/terraform.tfvars. Look it up via: curl -X POST https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token -d 'grant_type=password&client_id=$ID&client_secret=$SECRET&username=$USER&password=$PASS' | jq -r .access_token, then curl -H 'Authorization: Bearer <token>' 'https://api.contabo.com/v1/compute/images' | jq '.data[] | select(.name | contains(\"Ubuntu 24.04\"))'."
  }
}

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local mirror of the R2 inventory bucket. node-state reads/writes here; the workflow `aws s3 sync`s it before init. Contabo OAuth2 creds for the bwire account live under this dir at contabo/bwire/auth.yaml (sopsed)."
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
