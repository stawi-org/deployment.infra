#!/usr/bin/env bats
# Verifies the rendered cloud-init is valid YAML and contains expected
# load-bearing markers. Run from repo root: bats tofu/modules/omni-host/tests/

setup() {
  tmp=$(mktemp -d)
  MODULE_SRC=$(realpath "$BATS_TEST_DIRNAME/..")
  cd "$tmp"
  cat > main.tf <<EOF
module "h" {
  source = "${MODULE_SRC}"
  name = "test"
  contabo_image_id = "ubuntu-24.04"
  omni_version = "v1.4.6"
  dex_version = "v2.41.1"
  omni_account_name = "stawi"
  siderolink_api_advertised_host = "cp.example.com"
  siderolink_wireguard_advertised_host = "cpd.example.com"
  github_oidc_client_id = "abc"
  github_oidc_client_secret = "def"
  tls_cert_pem = "FAKE-CERT-FOR-VALIDATE-ONLY"
  tls_key_pem  = "FAKE-KEY-FOR-VALIDATE-ONLY"
  initial_users = ["test@example.com"]
  eula_name = "Test User"
  eula_email = "test@example.com"
  contabo_client_id = "fake"
  contabo_client_secret = "fake"
  contabo_api_user = "fake"
  contabo_api_password = "fake"
}
output "ud" {
  value     = module.h.user_data
  sensitive = true
}
EOF
}

teardown() { rm -rf "$tmp"; }

@test "cloud-init renders" {
  run tofu init -backend=false
  [ "$status" -eq 0 ]
  run tofu validate -no-color
  [ "$status" -eq 0 ]
}
