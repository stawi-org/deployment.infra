# tofu/layers/03-talos/variables.tf
variable "r2_account_id" {
  type        = string
  sensitive   = true
  description = "Cloudflare R2 account ID. Used to construct the S3-compatible endpoint for cross-layer terraform_remote_state reads."
}

variable "cluster_name" {
  type        = string
  default     = "stawi"
  description = "Omni cluster name. Must match tofu/shared/clusters/main.yaml's `Cluster.name` and the `omni.sidero.dev/cluster=<name>` label Omni stamps onto each Machine."
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used by the SOPS health-check fixture in sops-check.tf."
}

variable "ci_run_id" {
  type        = string
  default     = "local"
  description = "Set by CI to $GITHUB_RUN_ID; surfaced in any artifact metadata this layer emits."
}

variable "local_inventory_dir" {
  type        = string
  default     = "/tmp/inventory"
  description = "Local directory where the workflow syncs R2 production/inventory/ before plan."
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
    prod_label = optional(string, "prod")
  }))
  default     = []
  description = <<-EOT
    Cloudflare zones to publish cluster DNS into, computed from every
    load-balancer node across every provider (Contabo + OCI + on-prem).

    Per zone:
      - <prod_label>.<zone>  round-robin A/AAAA across nodes carrying
                             node.kubernetes.io/external-load-balancer="true";
                             omitted when no nodes match

    Default: prod_label="prod".

    The bare `cp.<zone>` round-robin is owned by the 00-omni-server
    layer (it points at the Omni dashboard host, orange-cloud) — this
    layer does not publish it. Per-CP `cp-<N>.<zone>` records are
    gone too: cluster API access is mediated by Omni's k8s-proxy at
    cp.<zone>, no direct talosctl-by-node DNS need.

    zone_id is passed directly (no Cloudflare API lookup), so a token
    scoped only to Zone:DNS:Edit is sufficient.
  EOT
}

variable "omni_endpoint" {
  type        = string
  default     = "https://cp.stawi.org"
  description = "Omni machine-api endpoint omnictl dials for cluster-template sync and per-machine label updates. cpd.<zone> (gray-cloud, direct-to-VPS, real LE cert) is the supported path; cp.<zone> is CF-proxied and the free plan downgrades HTTP/2 to HTTP/1.1, which breaks omnictl's gRPC client."
}
