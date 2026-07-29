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
  description = "Local mirror of the R2 inventory bucket. node-state reads/writes here; the workflow `aws s3 sync`s it before init."
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
  default = "v1.9.3"
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
# Threaded into module.omni_host_oci / module.omni_host_gcp so the on-host
# omni-backup.sh / omni-restore.sh pair can write to / read from R2 without
# baking credentials into a script committed to the repo.

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
  description = "Nginx image tag passed to omni-host modules. Reverse-proxies cp.<zone> to Omni's loopback UI."
}

variable "omni_host_provider" {
  description = "Substrate hosting omni-host: oci (A1.Flex) or gcp (Always Free e2-micro / STANDARD GCE)."
  type        = string
  default     = "gcp"
  validation {
    condition     = contains(["oci", "gcp"], var.omni_host_provider)
    error_message = "omni_host_provider must be 'oci' or 'gcp'."
  }
}

variable "omni_host_gcp_account" {
  description = "GCP accounts.yaml key for Omni host when omni_host_provider==gcp (auth under tofu/shared/accounts/gcp/<key>/)."
  type        = string
  default     = "stawi-timber"
}

variable "omni_host_gcp_region" {
  description = "GCP region for Omni. Always Free e2-micro is free only in us-west1, us-central1, us-east1."
  type        = string
  default     = "us-central1"
}

variable "omni_host_gcp_zone" {
  type    = string
  default = "us-central1-a"
}

variable "omni_host_gcp_machine_type" {
  description = "GCE machine type. e2-micro = Always Free eligible (1 GiB + swap); e2-small/medium if free tier is insufficient."
  type        = string
  default     = "e2-micro"
}
