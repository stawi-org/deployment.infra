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

variable "per_node_force_reinstall_generation" {
  type        = map(number)
  default     = {}
  description = <<-EOT
    Per-node override for force_reinstall_generation. Keyed by
    node_key (e.g. contabo-stawi-contabo-node-2). The effective
    generation for a node is
      var.force_reinstall_generation + lookup(map, node_key, 0)
    so bumping an entry here fires ensure-image for just that one
    node, leaving the other CPs untouched. Intended for surgical
    disaster recovery when one CP is broken but the others are
    healthy — bumping the cluster-wide variable would wipe the
    working CPs and take etcd below quorum.
  EOT
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token, Zone:DNS:Edit. Kept in this layer ONLY to destroy the legacy cp_dns records still in its state — the new publishing path lives in layer 03. Remove once layer 01's state is clean of cloudflare_dns_record resources."
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

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. Module reads use this; writes go directly to R2."
}
