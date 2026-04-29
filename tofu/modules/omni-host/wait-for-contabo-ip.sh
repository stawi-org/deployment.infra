#!/usr/bin/env bash
# data.external program. Reads a JSON query from stdin (instance_id +
# Contabo OAuth2 creds), polls Contabo's /v1/compute/instances/$ID
# until the v4 IP is populated, then prints {"ipv4": "..."} to stdout.
#
# Why we need this: Contabo's create call returns immediately with the
# instance object but no IP — the IP is assigned async (typically
# within ~30-90s). The contabo terraform provider's resource Read
# does not repopulate ip_config when the IP is later assigned, so
# downstream resources in the same apply (the cp.<zone> A record)
# see an empty value and Cloudflare rejects it. Poll the API ourselves.
set -euo pipefail

input=$(cat)
instance_id=$(echo "$input" | jq -r .instance_id)
client_id=$(echo "$input"    | jq -r .client_id)
client_secret=$(echo "$input"| jq -r .client_secret)
api_user=$(echo "$input"     | jq -r .api_user)
api_password=$(echo "$input" | jq -r .api_password)

token=$(curl -fsS -X POST 'https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  --data-urlencode "grant_type=password" \
  --data-urlencode "client_id=$client_id" \
  --data-urlencode "client_secret=$client_secret" \
  --data-urlencode "username=$api_user" \
  --data-urlencode "password=$api_password" \
  | jq -r .access_token)

if [[ -z "$token" || "$token" == "null" ]]; then
  echo "ERROR: failed to obtain Contabo OAuth2 token" >&2
  exit 1
fi

# Up to ~5 minutes — Contabo VPS provisioning typically settles in <2 min.
for attempt in $(seq 1 60); do
  resp=$(curl -fsS "https://api.contabo.com/v1/compute/instances/$instance_id" \
    -H "Authorization: Bearer $token" \
    -H "x-request-id: 00000000-0000-0000-0000-000000000001" \
    -H 'Accept: application/json')
  ip=$(echo "$resp" | jq -r '.data[0].ipConfig.v4.ip // empty')
  if [[ -n "$ip" && "$ip" != "null" ]]; then
    jq -nc --arg ip "$ip" '{ipv4: $ip}'
    echo "Contabo instance $instance_id got IP $ip on attempt $attempt." >&2
    exit 0
  fi
  sleep 5
done

echo "ERROR: Contabo never assigned an IPv4 to instance $instance_id within 5 minutes" >&2
exit 1
