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
  default = "v1.7.1"
}

variable "omni_eula_name" {
  type        = string
  description = "Name supplied to Omni's --eula-accept-name flag (Sidero EULA acceptance, required v1.7+). Sourced from the OMNI_EULA_NAME GitHub variable/secret."
}

variable "omni_eula_email" {
  type        = string
  description = "Email supplied to Omni's --eula-accept-email flag. Sourced from the OMNI_EULA_EMAIL GitHub variable/secret."
}

variable "dex_version" {
  type    = string
  default = "v2.41.1"
}

variable "cf_dns_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token for certbot's DNS-01 challenge (scoped to Zone:DNS:Edit on stawi.org). Sourced from CF_DNS_API_TOKEN GitHub secret."
}

variable "contabo_public_ssh_key" {
  type        = string
  default     = ""
  description = "Operator public SSH key (sourced from the CONTABO_PUBLIC_SSH_KEY GitHub secret). Authorised for root SSH on the omni-host VPS for diagnostics. Empty disables SSH login."
}

variable "omni_initial_users" {
  type        = string
  description = "Comma-separated list of email addresses promoted to Admin on first login. Each email must match the primary verified email GitHub returns to Dex. Sourced from the OMNI_INITIAL_USERS GitHub variable."
  validation {
    condition     = length(trimspace(var.omni_initial_users)) > 0
    error_message = "At least one initial admin email is required, otherwise the Omni UI will be locked on first login."
  }
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "sops_age_key" {
  type      = string
  sensitive = true
}

# ---- R2 backup / restore -----------------------------------------------------
# Threaded into module.omni_host so the on-host omni-backup.sh /
# omni-restore.sh pair can write to / read from R2 without baking
# credentials into a script committed to the repo.

variable "r2_access_key_id" {
  type        = string
  sensitive   = true
  description = "R2 access key ID with read+write on the tofu-state bucket. Same secret already used by the workflow's `aws s3 sync` step."
}

variable "r2_secret_access_key" {
  type      = string
  sensitive = true
}
