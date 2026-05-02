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
variable "nginx_version" {
  type        = string
  default     = "1.27-alpine"
  description = "Nginx image tag — alpine variant for size. Reverse-proxies cp.<zone> to Omni's loopback UI per Sidero's expose-omni-with-nginx-https reference config."
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

variable "ssh_authorized_keys" {
  type        = list(string)
  default     = []
  description = "Operator SSH public keys (sourced from the CONTABO_PUBLIC_SSH_KEY github secret). Authorised for root login on the omni-host VPS — used for diagnostics (Omni stack troubleshooting, container log inspection). Only honoured when ssh_enabled = true."
}

variable "ssh_enabled" {
  type        = bool
  default     = true
  description = <<-EOT
    Toggle whether SSH access is provisioned on the omni-host. When
    true (default) cloud-init threads ssh_authorized_keys onto root
    and sshd is configured with PermitRootLogin prohibit-password.
    When false, no keys are added and PermitRootLogin is no — sshd
    refuses every login attempt at PreAuth.

    Operator workflow for safely flipping to false:
      1. Apply with ssh_enabled = true (default), verify the host
         comes up cleanly (cluster-health green, /healthz 200).
      2. Set ssh_enabled = false in tfvars, bump
         force_reinstall_generation, apply.
    The reinstall lands the lockdown on a known-good host so a
    cloud-init bug can't deadlock recovery (we hit that on PR #131
    where lockdown + a transient networking issue at first boot
    locked us out completely).

    Break-glass with ssh_enabled = false is the Contabo serial
    console; the wg-users user-VPN keeps tunnel access independent
    of sshd.
  EOT
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

# ---- R2 backup / restore -----------------------------------------------------
# Daily snapshot of /var/lib/omni (embedded etcd + sqlite + master keys)
# uploaded to R2; on a fresh disk, omni-restore pulls the most recent
# snapshot before omni-keys + omni-stack come up. This is what makes a
# Contabo reinstall non-destructive — losing /var/lib/omni would
# otherwise lose every cluster Omni has ever provisioned.

variable "r2_account_id" {
  type        = string
  description = "Cloudflare R2 account ID — feeds the S3 endpoint URL the on-host backup/restore scripts use."
}

variable "r2_access_key_id" {
  type        = string
  sensitive   = true
  description = "R2 access key ID with read+write on r2_bucket_name. Reuses the existing tofu-state R2 credential pattern."
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

# ---- Contabo PUT-driven reinstall path ---------------------------------------
# Contabo's image_id-only PUT is silently a metadata update, so the contabo
# provider's own update path doesn't actually re-image a running disk. We use
# the same ensure-image.sh script the cluster nodes use (in node-contabo), and
# need the OAuth2 creds to call the Contabo API directly. Pulled from
# module.contabo_account_state in layer 00-omni-server (same source the
# contabo provider already reads from).
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

variable "force_reinstall_generation" {
  type        = number
  default     = 1
  description = <<-EOT
    Bump to force a Contabo reinstall of the omni-host VPS via
    null_resource.ensure_image. The canonical path for any cloud-init
    template change that needs to land on the running host (new
    sysctl, systemd unit, certbot config). omni-restore.service pulls
    the most recent /var/lib/omni snapshot from R2 on first boot, so
    as long as omni-backup.timer has fired recently the reinstall is
    non-destructive — every cluster, every Link, every machine UUID
    survives.
  EOT
  validation {
    condition     = var.force_reinstall_generation >= 1
    error_message = "force_reinstall_generation must be >= 1."
  }
}

# ---- WireGuard user-VPN ------------------------------------------------------
# Adds users to the wg-users interface on the omni-host. The user-VPN is
# distinct from SideroLink (Omni's own management mesh): different port,
# different keys, different /etc/wireguard config name. Full-tunnel egress
# (clients set AllowedIPs = 0.0.0.0/0,::/0) is supported via nftables NAT.
#
# Each user generates their own keypair locally and shares ONLY the
# public key — the server never has access to the user's private key.
# Auto-assigned VPN IP comes from sorted-by-name iteration order in
# main.tf, so it's stable across plans for any given user.
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
