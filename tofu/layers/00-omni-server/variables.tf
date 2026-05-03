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
# Threaded into module.omni_host_oci / module.omni_host_contabo so the on-host omni-backup.sh /
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

variable "bwire_availability_domain_index" {
  type        = number
  default     = 0
  description = "0-based index into bwire's availability_domains list for the omni-host VM. Default 0 picks AD-1; bump if AD-1 is out of A1.Flex capacity. Mirrors oracle-account-infra's per-node availability_domain_index pattern."
}

variable "etcd_backup_enabled" {
  type        = bool
  default     = false
  description = "Render --etcd-backup-s3 on the omni-server command line. Activate together with the EtcdBackupS3Configs resource (tofu/shared/clusters/etcd-backup-s3-configs.yaml.tmpl) and the cluster-template backupConfiguration block. See modules/omni-host/variables.tf for the architecture note."
}

variable "vpn_users" {
  type = map(object({
    public_key = string
  }))
  default     = {}
  description = "Map of WireGuard user-VPN peers (name -> {public_key}). See modules/omni-host/variables.tf for the add-user workflow. Adding/removing entries needs a force_reinstall_generation bump to land on the running host."
}

variable "nginx_version" {
  type        = string
  default     = "1.27-alpine"
  description = "Nginx image tag passed to omni-host-contabo. Reverse-proxies cp.<zone> to Omni's loopback UI."
}

variable "omni_host_provider" {
  description = "Substrate hosting omni-host. 'contabo' uses an existing Contabo VPS; 'oci' uses an OCI A1.Flex VM in bwire."
  type        = string
  default     = "oci"
  validation {
    condition     = contains(["contabo", "oci"], var.omni_host_provider)
    error_message = "omni_host_provider must be 'contabo' or 'oci'."
  }
}

variable "omni_host_contabo_vps_id" {
  description = "Contabo VPS ID adopted as the omni-host when omni_host_provider=='contabo'."
  type        = string
  default     = "202727781"
}

variable "omni_host_contabo_region" {
  description = "Contabo region for the omni-host VPS."
  type        = string
  default     = "EU"
}

# Defaulted to empty so the unconditional provider "contabo" block in
# main.tf can initialize when omni_host_provider="oci" without
# requiring operator-supplied creds. The actual Contabo API is never
# called with these values when count-gated modules have count=0;
# Task 11's tfvars flip is what activates the contabo path and
# requires real creds in the workflow's environment.
variable "contabo_client_id" {
  type      = string
  sensitive = true
  default   = ""
}

variable "contabo_client_secret" {
  type      = string
  sensitive = true
  default   = ""
}

variable "contabo_api_user" {
  type      = string
  sensitive = true
  default   = ""
}

variable "contabo_api_password" {
  type      = string
  sensitive = true
  default   = ""
}

variable "force_reinstall_generation" {
  description = <<-EOT
    Operator escape hatch for forcing a fleet-wide Contabo VPS
    reinstall on next apply, decoupled from schematic_id changes.
    Bump in terraform.tfvars (e.g. 1 → 2) to invalidate every
    null_resource.ensure_image trigger; ensure-image.sh runs with
    FORCE_REINSTALL=1 and PUTs unconditionally regardless of
    current imageId.

    Use cases:
      - Recover from "stuck Talos" / lost SideroLink registration.
      - Refresh kernel cmdline after Omni's join token rotates.
      - Smoke-test reinstall paths.

    Routine reinstalls driven by a real schematic change still fire
    automatically through the target_image_id trigger; this knob
    only matters for "want a reinstall NOW".
  EOT
  type        = number
  default     = 1
  validation {
    condition     = var.force_reinstall_generation >= 1
    error_message = "force_reinstall_generation must be >= 1."
  }
}
