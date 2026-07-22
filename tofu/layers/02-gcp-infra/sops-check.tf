# GENERATED — do not edit manually. Source: tofu/shared/sops-check.tf.tmpl
# Synced into each layer by scripts/sync-sops-check.sh (pre-commit).
#
# Fails plan if the SOPS provider cannot decrypt the validation fixture.
# Catches: stale age key in CI, recipient-set drift, missing SOPS_AGE_KEY env.
data "sops_file" "validation_fixture" {
  source_file = "${path.module}/../../shared/sops-fixture.age.yaml"
}

check "sops_provider_healthy" {
  assert {
    condition     = try(data.sops_file.validation_fixture.data["canary"], null) == "healthy"
    error_message = "SOPS provider cannot decrypt tofu/shared/sops-fixture.age.yaml. Check SOPS_AGE_KEY / TF_VAR_sops_age_key; do not proceed."
  }
}
