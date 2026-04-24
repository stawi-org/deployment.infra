#!/usr/bin/env bash
set -euo pipefail
TOKEN=$(curl -sS -XPOST \
  -d "grant_type=password&client_id=$CONTABO_CLIENT_ID&client_secret=$CONTABO_CLIENT_SECRET&username=$CONTABO_API_USER&password=$CONTABO_API_PASSWORD" \
  https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token | jq -r .access_token)
curl -sS -H "Authorization: Bearer $TOKEN" \
  -H "x-request-id: $(uuidgen)" \
  "https://api.contabo.com/v1/compute/instances?size=100"
