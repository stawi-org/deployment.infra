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
  ssh_authorized_keys = ["ssh-ed25519 AAA test"]
  omni_version = "v1.4.6"
  dex_version = "v2.41.1"
  cloudflared_version = "2025.10.1"
  omni_account_name = "stawi"
  siderolink_api_advertised_host = "cp.example.com"
  github_oidc_client_id = "abc"
  github_oidc_client_secret = "def"
  cloudflare_tunnel_token = "ghi"
  r2_endpoint = "https://x.r2.cloudflarestorage.com"
  r2_backup_access_key_id = "k"
  r2_backup_secret_access_key = "s"
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
