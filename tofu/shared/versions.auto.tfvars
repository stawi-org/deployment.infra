# tofu/shared/versions.auto.tfvars
# Single source of truth for Talos + Kubernetes versions across all layers.
# Loaded automatically by OpenTofu when symlinked from a layer directory.

talos_version      = "v1.12.6" # matches the Ansible baseline
kubernetes_version = "v1.35.2" # bundled with Talos v1.12.6
flux_version       = "v2.4.0"  # pin a specific FluxCD version
