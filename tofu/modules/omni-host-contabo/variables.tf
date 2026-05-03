# tofu/modules/omni-host-contabo/variables.tf

# ---- Substrate-specific (Contabo) --------------------------------------------

variable "vps_id" {
  description = "Contabo VPS instance ID adopted by this module (the existing VPS that becomes the omni-host)."
  type        = string
}

variable "name" {
  description = "Hostname / display_name for the omni-host VPS."
  type        = string
}

variable "region" {
  description = "Contabo region (e.g. EU)."
  type        = string
}

variable "image_id" {
  description = "Contabo Ubuntu LTS image UUID. Provided by the contabo-image-lookup module at the layer level."
  type        = string
}

variable "force_reinstall_generation" {
  description = "Bump to force a full reinstall via Contabo API. Mirrors node-contabo's mechanism."
  type        = number
  default     = 1
}

variable "contabo_client_id" {
  type      = string
  sensitive = true
}

variable "contabo_client_secret" {
  type      = string
  sensitive = true
}

variable "contabo_api_user" {
  type      = string
  sensitive = true
}

variable "contabo_api_password" {
  type      = string
  sensitive = true
}

# ---- Substrate-agnostic (same shape as omni-host-oci) ------------------------

variable "omni_version" { type = string }
variable "dex_version" { type = string }

variable "nginx_version" {
  type        = string
  default     = "1.27-alpine"
  description = "Nginx image tag — alpine variant for size. Reverse-proxies cp.<zone> to Omni's loopback UI per Sidero's expose-omni-with-nginx-https reference config."
}

variable "omni_account_id" {
  description = "Omni account UUID, baked into every Machine's SideroLink config. Pinned (lifecycle ignore_changes upstream)."
  type        = string
}

variable "dex_omni_client_secret" {
  description = "Dex OAuth client secret for Omni. Pinned upstream."
  type        = string
  sensitive   = true
}

variable "omni_account_name" {
  type        = string
  description = "Top-level Omni account name (e.g. \"stawi\")."
}

variable "siderolink_api_advertised_host" {
  type        = string
  description = "Browser-facing Omni hostname (orange-cloud Cloudflare). Serves the UI on :443 via nginx and the OIDC discovery path /dex."
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

variable "cf_dns_api_token" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Cloudflare API token for certbot's DNS-01 challenge.
    omni-cert-bootstrap.service issues Let's Encrypt certs on first
    boot; certbot.timer renews them. Reuses the existing
    CLOUDFLARE_API_TOKEN secret (already required for DNS record
    management) — needs Zone:DNS:Edit on the stawi.org zone.
  EOT
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

variable "etcd_backup_enabled" {
  type        = bool
  default     = false
  description = "Render --etcd-backup-s3 on the omni-server command line. Pair with an EtcdBackupS3Configs resource in Omni and a backupConfiguration block in the cluster template."
}

variable "ssh_authorized_keys" {
  type        = list(string)
  default     = []
  description = "Operator SSH public keys. Authorised for root login on the omni-host VPS — used for diagnostics (Omni stack troubleshooting, container log inspection)."
}

variable "vpn_users" {
  type = map(object({
    public_key = string
  }))
  default     = {}
  description = <<-EOT
    Map of user-name -> {public_key} for the wg-users user-VPN.

    Workflow to add a user:
      1. User runs locally:
           wg genkey | tee priv | wg pubkey > pub
         (private key stays on user device)
      2. User shares only `pub` with operator (secure channel).
      3. Operator adds an entry here, bumps force_reinstall_generation,
         apply.
      4. Operator runs `cat /etc/wireguard/wg-users.pubkey` on the
         omni-host once (or fetches from a tofu output) and gives
         the user the SERVER's public key plus the assigned VPN IP.
      5. User assembles their .conf from the wg_user_client_config
         output (placeholder for their own private key).

    Removing a user: drop their entry, bump force_reinstall_generation.
  EOT
}

# ---- R2 backup / restore -----------------------------------------------------

variable "r2_account_id" {
  type        = string
  description = "Cloudflare R2 account ID — feeds the S3 endpoint URL the on-host backup/restore scripts use."
}

variable "r2_access_key_id" {
  type        = string
  sensitive   = true
  description = "R2 access key ID with read+write on r2_bucket_name."
}

variable "r2_secret_access_key" {
  type      = string
  sensitive = true
}

variable "r2_bucket_name" {
  type        = string
  default     = "cluster-tofu-state"
  description = "R2 bucket holding Omni snapshots. Defaulting to the tofu-state bucket keeps backups in the same blast radius as the rest of the cluster."
}

variable "r2_backup_prefix" {
  type        = string
  default     = "production/omni-backups"
  description = "Object key prefix under r2_bucket_name where omni-*.tar.gz snapshots are written."
}
