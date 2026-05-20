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
  description = "Cloudflare API token with Zone:DNS:Edit on every zone. Transitional — needed only while module.cluster_dns lingers in this layer's tfstate (refresh requires auth). Deleted by Task 8 of dns-layer-split."
}

variable "omni_endpoint" {
  type        = string
  default     = "https://cp.stawi.org"
  description = "Omni machine-api endpoint omnictl dials for cluster-template sync and per-machine label updates. cpd.<zone> (gray-cloud, direct-to-VPS, real LE cert) is the supported path; cp.<zone> is CF-proxied and the free plan downgrades HTTP/2 to HTTP/1.1, which breaks omnictl's gRPC client."
}

variable "talos_version" {
  type        = string
  description = "Talos version pinned for this cluster (e.g. v1.13.0). Used as a path component for R2 per-node-patch artifacts so multi-version clusters don't collide. Surfaced from tofu/shared/versions.auto.tfvars.json by the workflow."
}
