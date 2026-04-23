# tofu/layers/00-talos-secrets/main.tf
resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# Capture the operator-supplied SOPS age key into state on first apply.
# After first apply, the stored `output` value is the authoritative source —
# changes to var.sops_age_key (e.g. rotation of the GitHub secret) are ignored
# until the resource is tainted and re-applied.
resource "terraform_data" "sops_age_key" {
  input = var.sops_age_key
  lifecycle {
    ignore_changes = [input]
  }
}
