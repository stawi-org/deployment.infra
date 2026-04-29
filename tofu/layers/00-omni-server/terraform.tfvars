# tofu/layers/00-omni-server/terraform.tfvars
#
# SSH public keys allowed during cloud-init bootstrap of the omni-host
# VPS and via Contabo console for break-glass access. Public keys
# are not secrets — they're OK to commit. Add a key:
#   1. append to the list below
#   2. tofu apply
#   3. (cloud-init only fires once; for an already-provisioned host,
#      tofu will plan an instance recreate due to user_data change.
#      To rotate on a live host, SSH in via Contabo console and edit
#      ~opadmin/.ssh/authorized_keys directly. Or `tofu taint
#      module.omni_host.contabo_instance.this` for a clean rebuild —
#      restore the omni state from R2 backup.)

ssh_authorized_keys = [
  # Replace with your operator's actual public keys.
  # Example:
  #   "ssh-ed25519 AAAAC3Nzac... operator@laptop",
]

# Contabo image ID for Ubuntu 24.04 LTS Minimal. Look up once via:
#   curl -X POST https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token \
#     -d "grant_type=password&client_id=$ID&client_secret=$SECRET&username=$USER&password=$PASS" \
#     | jq -r .access_token
# Then:
#   curl -H "Authorization: Bearer $TOKEN" 'https://api.contabo.com/v1/compute/images' \
#     | jq '.data[] | select(.name | contains("Ubuntu 24.04"))'
# Drop the .id field below. Image IDs are stable per Contabo's catalog.
contabo_ubuntu_24_04_image_id = ""
