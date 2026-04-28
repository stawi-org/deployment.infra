variable "r2_account_id" {
  type        = string
  description = "Cloudflare R2 account ID — feeds the S3 endpoint URL."
}

variable "talos_version" {
  type        = string
  description = "Talos version for the cluster, e.g. v1.13.0. Read from versions.auto.tfvars.json."
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version for the cluster, e.g. v1.35.2. Read from versions.auto.tfvars.json."
}

variable "omni_service_account_key" {
  type        = string
  sensitive   = true
  description = "Service-account key from `omnictl serviceaccount create` — created during Phase B step 6.7. Empty until then; layer apply waits until Omni is live."
  default     = ""
}

# Machine UUIDs are discovered via `omnictl machine list` after nodes register
# with Omni (Phase B step 7.4). Provide them as lists to wire into the cluster.
# Defaults to empty — tofu validate passes; tofu apply waits for Phase B.
variable "controlplane_machine_ids" {
  type        = list(string)
  description = "Omni machine UUIDs to assign as control-plane nodes. Populated in Phase B after nodes register."
  default     = []
}

variable "worker_machine_ids" {
  type        = list(string)
  description = "Omni machine UUIDs to assign as worker nodes. Populated in Phase B after nodes register."
  default     = []
}

variable "age_recipients" {
  type        = string
  description = "Comma-separated age recipient pubkeys. Used to re-encrypt on write."
}

variable "sops_age_key" {
  type      = string
  sensitive = true
}
