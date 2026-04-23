# tofu/layers/04-flux/outputs.tf
output "flux_namespace" { value = kubernetes_namespace.flux_system.metadata[0].name }
output "flux_version" { value = var.flux_version }
