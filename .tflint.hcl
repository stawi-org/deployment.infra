# .tflint.hcl — TFLint configuration for deployment.infra
# Layers share a common variables.auto.tfvars that declares all version pins
# (talos_version, kubernetes_version, flux_version, sops_age_key) even if a
# given layer only uses a subset.  Silencing unused_declarations avoids
# false-positives for that intentional pattern.
# Module directories inherit provider version constraints from their calling
# layer, so terraform_required_version / terraform_required_providers are not
# enforced at the module level.

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

rule "terraform_unused_declarations" {
  enabled = false
}

rule "terraform_required_version" {
  enabled = false
}

rule "terraform_required_providers" {
  enabled = false
}
