# tofu/layers/00-talos-secrets/variables.tf
variable "talos_version" {
  type        = string
  description = "Talos OS version (e.g. v1.13.0-rc.0). Provided via shared/versions.auto.tfvars.json."
}

variable "kubernetes_version" {
  type        = string
  description = "Kubernetes version (e.g. v1.36.0). Provided via shared/versions.auto.tfvars.json."
}

variable "flux_version" {
  type        = string
  description = "FluxCD version. Unused in this layer, declared for consistent shared tfvars loading."
}

variable "sops_age_key" {
  type        = string
  sensitive   = true
  description = "Existing age private key (AGE-SECRET-KEY-1...) used to decrypt SOPS-encrypted manifests. Captured into state on first apply and ignored thereafter — to rotate, taint sops_age_key and re-apply."
}
