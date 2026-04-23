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

variable "contabo_accounts" {
  type = map(object({
    auth = object({
      oauth2_client_id     = string
      oauth2_client_secret = string
      oauth2_user          = string
      oauth2_pass          = string
    })
    labels      = optional(map(string), {})
    annotations = optional(map(string), {})
    nodes = map(object({
      role        = optional(string, "controlplane")
      product_id  = string
      region      = optional(string, "EU")
      labels      = optional(map(string), {})
      annotations = optional(map(string), {})
    }))
  }))
  default     = {}
  description = <<-EOT
    Contabo account inventory. Each account supplies its own credentials and
    node inventory. Node keys must remain globally unique across all accounts
    because they become Terraform resource keys and Talos node names.
  EOT

  validation {
    condition = length(flatten([
      for account_key, account in var.contabo_accounts : [
        for node_key, node in account.nodes :
        "${account_key}/${node_key}" if(
          contains(["controlplane", "worker"], node.role)
          && length(node_key) <= 63
          && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", node_key))
        )
      ]
      ])) == length(toset(flatten([
        for account_key, account in var.contabo_accounts : [
          for node_key, _ in account.nodes : node_key
        ]
    ])))
    error_message = "Contabo node keys must be valid RFC 1123 labels, unique across accounts, and node role must be controlplane or worker."
  }
}

variable "controlplane_nodes" {
  type = map(object({
    product_id = string
    region     = string
  }))
  default     = {}
  description = <<-EOT
    Legacy flat control-plane inventory. Kept for bootstrap compatibility.
    Prefer contabo_accounts in the R2 inventory file.
  EOT

  validation {
    condition = length([
      for node_key, _ in var.controlplane_nodes :
      node_key if length(node_key) <= 63 && can(regex("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", node_key))
    ]) == length(var.controlplane_nodes)
    error_message = "Legacy controlplane node keys must be valid RFC 1123 labels."
  }
}

variable "contabo_client_id" {
  type      = string
  sensitive = true
  default   = null
}

variable "contabo_client_secret" {
  type      = string
  sensitive = true
  default   = null
}

variable "contabo_api_user" {
  type      = string
  sensitive = true
  default   = null
}

variable "contabo_api_password" {
  type      = string
  sensitive = true
  default   = null
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
