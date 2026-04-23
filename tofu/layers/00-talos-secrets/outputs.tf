# tofu/layers/00-talos-secrets/outputs.tf
output "machine_secrets" {
  description = "Talos machine secrets (cluster PKI). Consumed by layer 03 for config apply."
  value       = talos_machine_secrets.this.machine_secrets
  sensitive   = true
}

output "client_configuration" {
  description = "Talos client configuration (CA, client cert/key). Consumed by layer 03."
  value       = talos_machine_secrets.this.client_configuration
  sensitive   = true
}

output "sops_age_key" {
  description = "SOPS age private key locked into state on first apply. Consumed by layer 04."
  value       = terraform_data.sops_age_key.output
  sensitive   = true
}
