variable "name" {
  type        = string
  description = "Hostname for the Omni host VPS, e.g. cluster-omni-contabo."
}

variable "contabo_product_id" {
  type        = string
  default     = "V94" # Same shape the existing Contabo CPs use; V47 was retired by Contabo.
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
variable "caddy_version" {
  type        = string
  default     = "2.10-alpine"
  description = "Caddy image tag — version pinned to alpine variant for size."
}

variable "omni_account_name" {
  type        = string
  description = "Top-level Omni account name (e.g. \"stawi\")."
}

variable "siderolink_api_advertised_host" {
  type        = string
  description = "Browser-facing Omni hostname (orange-cloud Cloudflare). Serves the UI on :443 via Caddy and the OIDC discovery path /dex."
}

variable "siderolink_wireguard_advertised_host" {
  type        = string
  description = "Talos-facing Omni hostname (gray-cloud direct A → VPS public IP). Serves machine-api :8090, k8s-proxy :8100, and WireGuard :50180/udp."
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

# Cloudflare API access — passed to the VPS so cloud-init can patch
# the cp.<zone> + cpd.<zone> DNS records with the VPS's actual public
# IP at first boot. Tofu cannot do this itself: Contabo assigns the
# IP async post-create, and the contabo terraform provider's resource
# Read does not refresh ip_config, so a same-apply downstream DNS
# resource sees an empty value. Letting the VPS fix its own DNS is
# the most robust path.
variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_zone_id" {
  type        = string
  description = "Zone ID for the DNS hostnames the VPS owns (e.g. stawi.org)."
}

variable "cloudflare_dns_record_ids" {
  type        = map(string)
  description = "Map of short hostname → CF DNS record ID. cloud-init PATCHes each record's content with the VPS's resolved public IP. Pre-created in tofu so the IDs are known."
}

variable "tls_cert_pem" {
  type        = string
  sensitive   = true
  description = "PEM-encoded TLS certificate (Cloudflare Origin Cert, multi-SAN covering siderolink_api_advertised_host + siderolink_wireguard_advertised_host in both zones)."
}

variable "tls_key_pem" {
  type        = string
  sensitive   = true
  description = "PEM-encoded private key matching tls_cert_pem."
}

variable "initial_users" {
  type        = list(string)
  description = "Email addresses promoted to Admin on first login. Empty list means no admins — UI will be locked."
  validation {
    condition     = length(var.initial_users) > 0
    error_message = "At least one initial admin email is required."
  }
}

variable "eula_name" {
  type        = string
  description = "Name supplied to Omni's --eula-accept-name flag (Sidero EULA, required v1.7+)."
}

variable "eula_email" {
  type        = string
  description = "Email supplied to Omni's --eula-accept-email flag."
}
