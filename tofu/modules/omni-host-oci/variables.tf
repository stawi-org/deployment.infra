variable "name" {
  type        = string
  description = "Hostname for the Omni host VPS, e.g. cluster-omni-contabo."
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

variable "ssh_authorized_keys" {
  type        = list(string)
  default     = []
  description = "Operator SSH public keys (sourced from the CONTABO_PUBLIC_SSH_KEY github secret). Authorised for root login on the omni-host VPS — used for diagnostics (Omni stack troubleshooting, container log inspection). Only honoured when ssh_enabled = true."
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

# ---- Omni native etcd backup ------------------------------------------------
# Omni v1.7+ ships a builtin etcd-backup feature that writes point-in-time
# consistent etcd snapshots (raft-driven, incremental) to S3-compatible
# object storage on a per-cluster schedule.
#
# Architecture (verified against Omni docs 2026-05-02):
#   - Server flag --etcd-backup-s3 is a BOOLEAN — it only enables the
#     S3 destination; bucket/endpoint/region/credentials do NOT come
#     from server flags or env vars.
#   - All S3 connection details live in an `EtcdBackupS3Configs.omni.sidero.dev`
#     resource (cluster-scoped, applied via `omnictl apply`).
#   - Per-cluster enable + cadence lives in the Cluster template's
#     `backupConfiguration: { interval: <duration> }` block.
#
# The destination bucket (omni-backup-storage in OCI bwire) and its
# Customer Secret Key are managed in tofu/shared/clusters/etcd-backup-
# s3-configs.yaml.tmpl + sync-cluster-template.yml — NOT here. This
# var only toggles the server-side flag.
#
# Replaces the host-level tarball flow for cluster-etcd state. The
# tarball stays for things Omni doesn't natively back up: master keys
# at /var/lib/omni/keys, /etc/wireguard, /etc/letsencrypt, sqlite
# audit log at /var/lib/omni/omni.db.

variable "etcd_backup_enabled" {
  type        = bool
  default     = false
  description = "Render --etcd-backup-s3 on the omni-server command line. Pair with an EtcdBackupS3Configs resource in Omni and a backupConfiguration block in the cluster template."
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

# --- OCI substrate ---------------------------------------------------------

variable "compartment_ocid" {
  type        = string
  description = "OCID of the bwire compartment that owns the omni-host VM, VCN, and reserved IP."
}

variable "availability_domain_index" {
  type        = number
  default     = 0
  description = "0-based index into the tenancy's availability_domains list. Default 0 picks the first AD; bump if AD-1 is out of A1.Flex capacity. Mirrors the pattern used by oracle-account-infra — operator doesn't have to know the AD-name string."
  validation {
    condition     = var.availability_domain_index >= 0
    error_message = "availability_domain_index must be >= 0."
  }
}

variable "shape" {
  type        = string
  default     = "VM.Standard.A1.Flex"
  description = "OCI compute shape. A1.Flex is ARM Always-Free."
}

variable "ocpus" {
  type        = number
  default     = 2
  description = "vCPU count. 2 OCPUs leaves room for a sibling cluster-CP VM in the same tenancy under the 4-OCPU Always-Free ARM cap."
}

variable "memory_gb" {
  type        = number
  default     = 12
  description = "Memory (GB). 2 VMs at 12 GB exactly fills the 24-GB Always-Free ARM cap."
}

variable "boot_volume_size_gb" {
  type        = number
  default     = 90
  description = "Boot volume size (GB). 2 VMs at 90 GB plus the cluster CP fits inside the 200-GB Always-Free block-volume cap."
}

variable "ubuntu_image_ocid" {
  type        = string
  description = "OCI Ubuntu 24.04 LTS Minimal aarch64 image OCID. Looked up by the caller via oci_core_images data source (operating_system='Canonical Ubuntu', operating_system_version='24.04', shape='VM.Standard.A1.Flex')."
}

variable "vcn_cidr" {
  type        = string
  default     = "10.42.0.0/16"
  description = "Dedicated VCN CIDR for the omni-host. Separate from oracle-account-infra's cluster-node VCN to keep blast radius small."
}

variable "subnet_cidr" {
  type        = string
  default     = "10.42.1.0/24"
  description = "Subnet CIDR within the omni-host VCN."
}

variable "enable_ipv6" {
  type        = bool
  default     = true
  description = "Enable IPv6 on the VCN + VNIC. Required for cp/cpd AAAA records."
}
