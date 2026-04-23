# tofu/layers/01-contabo-infra/variables.tf
variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "flux_version" {
  type = string
}


variable "force_reinstall_generation" {
  type        = number
  default     = 0
  description = <<-EOT
    Bump this (e.g. 0 → 1) to force a disk-wipe reinstall of ALL
    Contabo CPs on the next apply. Cluster goes down for ~10 minutes
    while the 3 CPs re-image in parallel; etcd, volumes, and
    workloads are lost on those nodes. Do NOT bump for normal Talos
    version changes — use the in-place upgrade path instead.

    Recognised uses:
      - initial onboarding when imported instances boot a wrong OS
      - disaster recovery (unrecoverable etcd, corrupted CP)
      - deliberate clean-slate rebuild

    Plumbed into modules/node-contabo/null_resource.ensure_image.
  EOT
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = <<-EOT
    Cloudflare API token. Must have Zone:DNS:Edit on every zone listed
    in var.cp_dns_zones. Supplied via TF_VAR_cloudflare_api_token from
    the CLOUDFLARE_API_TOKEN GitHub Actions secret.
  EOT
}

variable "cp_dns_zones" {
  type = list(object({
    zone    = string
    zone_id = string
    label   = string
    indexed = bool
  }))
  description = <<-EOT
    Cloudflare zones to publish CP DNS into. For each entry the module
    creates <label>.<zone> as a round-robin across all CPs. If
    `indexed = true`, additionally creates <label>-1.<zone>,
    <label>-2.<zone>, ... (1-indexed, stable across node renames).

    Every resulting DNS name is automatically added to the cluster
    certSANs via the cp_cert_sans output. var.cloudflare_api_token
    must carry Zone:DNS:Edit on every listed zone_id.

    zone_id is passed directly (no API lookup) so the token can be
    tightly scoped — no Zone:Zone:Read permission needed.
  EOT
}

variable "extra_cert_sans" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Additional DNS names to include in the apiserver + talosd certSANs
    that this layer is NOT responsible for resolving. Use for any
    externally-managed name that clients might address the cluster
    through but whose zone isn't in Cloudflare (or isn't in our CF
    account). The operator sets up resolution externally; this
    variable only ensures the certs are valid for the name.

    For Cloudflare-managed zones, prefer extending cp_dns_zones so the
    DNS record and the cert SAN stay in sync automatically.
  EOT
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID; used for the S3-compatible AWS provider endpoint."
}
