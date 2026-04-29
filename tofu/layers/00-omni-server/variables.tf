variable "r2_account_id" {
  type        = string
  description = "Cloudflare R2 account ID — feeds the S3 endpoint URL for the tofu state backend."
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:Read + DNS:Edit on antinvestor.com + stawi.org."
}

variable "cloudflare_zone_id_stawi" {
  type        = string
  description = "Cloudflare zone ID for stawi.org — sole DNS zone for the Omni control plane."
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
  type    = string
  default = "v1.4.6"
}

variable "dex_version" {
  type    = string
  default = "v2.41.1"
}

variable "omni_tls_cert" {
  type        = string
  sensitive   = true
  description = "PEM-encoded Cloudflare Origin Certificate covering cp.<zone> and cpd.<zone> in both DNS zones (antinvestor.com + stawi.org). Sourced from a GitHub secret."
}

variable "omni_tls_key" {
  type        = string
  sensitive   = true
  description = "PEM-encoded private key matching omni_tls_cert. Sourced from a GitHub secret."
}

variable "omni_initial_users" {
  type        = list(string)
  default     = ["bwire517@gmail.com", "joakimbwire23@gmail.com"]
  description = "Email addresses promoted to Admin on first login. Must match the email field GitHub returns to Dex (the user's primary verified email)."
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "sops_age_key" {
  type      = string
  sensitive = true
}
