# tofu/layers/03-talos/variables.tf
variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID. Used to construct the S3-compatible endpoint for cross-layer terraform_remote_state reads."
}

variable "talos_version" {
  type = string
}

variable "kubernetes_version" {
  type = string
}

variable "flux_version" {
  type = string
}

variable "cluster_name" {
  type    = string
  default = "antinvestor-cluster"
}

variable "cluster_endpoint" {
  type = string
}

variable "force_talos_reapply_generation" {
  type        = string
  default     = "1"
  description = "Bump this (1 -> 2) to force all talos_machine_configuration_apply resources to be destroyed + recreated on the next apply. Use when nodes are stuck in a bad state (e.g. kubelet ImagePullBackOff) and need a reboot triggered by tofu. Feeds into terraform_data config-hash inputs and replace_triggered_by fires on change."
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "ci_run_id" {
  type        = string
  default     = "local"
  description = "Set by CI to $GITHUB_RUN_ID; used only for audit metadata in machine-configs.yaml."
}

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan. Module reads use this; writes go directly to R2."
}

variable "cloudflare_api_token" {
  type        = string
  sensitive   = true
  description = "Cloudflare API token with Zone:DNS:Edit on every zone listed in cp_dns_zones. Supplied via TF_VAR_cloudflare_api_token from the CLOUDFLARE_API_TOKEN GitHub Actions secret."
}

variable "cp_dns_zones" {
  type = list(object({
    zone       = string
    zone_id    = string
    cp_label   = optional(string, "cp")
    prod_label = optional(string, "prod")
  }))
  default     = []
  description = <<-EOT
    Cloudflare zones to publish cluster DNS into, computed from every
    controlplane node across every provider (Contabo + OCI + on-prem).

    Per zone:
      - <cp_label>.<zone>      round-robin A/AAAA across ALL CPs
      - <cp_label>-<N>.<zone>  per-CP A/AAAA, 1-indexed by sorted node key
      - <prod_label>.<zone>    round-robin A/AAAA across nodes carrying
                               node.kubernetes.io/external-load-balancer="true";
                               omitted when no nodes match

    Defaults: cp_label="cp", prod_label="prod".

    cp-* names are added to apiserver + talosd cert SANs locally. prod-*
    aren't — they point at LB workers, not apiserver.
    zone_id is passed directly (no Cloudflare API lookup), so a token
    scoped only to Zone:DNS:Edit is sufficient.
  EOT
}

variable "extra_cert_sans" {
  type        = list(string)
  default     = []
  description = "Additional DNS names to add to apiserver + talosd cert SANs (resolved externally, not published by this layer)."
}

variable "admin_cidrs" {
  type        = list(string)
  default     = []
  description = "Optional operator-supplied CIDRs (IPv4 or IPv6) allowed to reach Talos API (:50000) and Kubernetes API (:6443) in addition to GitHub Actions runner ranges (auto-fetched from api.github.com/meta). Leave empty to restrict admin access to CI only."
}

variable "talos_apply_skip" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Node keys to exclude from talos_machine_configuration_apply and
    from the wait_apiserver probe. Use for nodes that are temporarily
    unreachable on :50000 from CI — an apply against them wedges the
    whole run for 10+ min. Entries remain in controlplane_nodes /
    worker_nodes / node-state / DNS / cert SANs so they don't vanish
    from the cluster's declared shape; they just don't receive the
    talosctl-driven apply pass.
  EOT
}
