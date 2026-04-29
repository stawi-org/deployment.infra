# tofu/layers/00-omni-server/terraform.tfvars

# Contabo image ID for Ubuntu 24.04 LTS Minimal. Look up once via:
#   curl -X POST https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token \
#     -d "grant_type=password&client_id=$ID&client_secret=$SECRET&username=$USER&password=$PASS" \
#     | jq -r .access_token
# Then:
#   curl -H "Authorization: Bearer $TOKEN" 'https://api.contabo.com/v1/compute/images' \
#     | jq '.data[] | select(.name | contains("Ubuntu 24.04"))'
# Drop the .id field below. Image IDs are stable per Contabo's catalog.
contabo_ubuntu_24_04_image_id = ""
