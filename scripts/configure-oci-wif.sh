#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="${1:?auth json path required}"
mkdir -p "$HOME/.oci"
: > "$HOME/.oci/config"

COUNT=$(jq 'length' "$AUTH_FILE")
if [[ "$COUNT" -eq 0 ]]; then
  echo "::notice::no OCI auth profiles configured"
  exit 0
fi

for i in $(seq 0 $((COUNT - 1))); do
  profile=$(jq -r ".[$i].profile" "$AUTH_FILE")
  client=$(jq -r ".[$i].oidc_client_identifier" "$AUTH_FILE")
  domain=$(jq -r ".[$i].domain_base_url" "$AUTH_FILE")
  tenancy=$(jq -r ".[$i].tenancy_ocid" "$AUTH_FILE")
  region=$(jq -r ".[$i].region" "$AUTH_FILE")

  echo "::group::OCI profile [$profile]"
  if [[ "$client" != *:* ]]; then
    echo "::error::OCI profile $profile oidc_client_identifier must be '<clientId>:<clientSecret>'"
    exit 1
  fi

  client_id_only="${client%%:*}"
  echo "diag: fetching GH OIDC JWT for audience length=${#client_id_only}"
  GH_JWT=$(curl -fsSL \
    -H "Authorization: Bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
    "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${client_id_only}" \
    | jq -r .value) || { echo "::error::GH OIDC JWT fetch failed for $profile"; exit 1; }

  JWT_PAYLOAD_B64=$(printf '%s' "$GH_JWT" | cut -d. -f2)
  while [[ $((${#JWT_PAYLOAD_B64} % 4)) -ne 0 ]]; do JWT_PAYLOAD_B64+="="; done
  JWT_CLAIMS=$(printf '%s' "$JWT_PAYLOAD_B64" | tr '_-' '/+' | base64 -d 2>/dev/null)
  echo "diag: JWT sub=$(jq -r .sub <<<"$JWT_CLAIMS")"
  echo "diag: JWT iss=$(jq -r .iss <<<"$JWT_CLAIMS")"
  echo "diag: JWT aud=$(jq -r .aud <<<"$JWT_CLAIMS")"

  KEY="$HOME/.oci/upst_${profile}.key"
  UPST="$HOME/.oci/upst_${profile}.token"
  openssl genrsa -out "$KEY" 2048 2>/dev/null
  chmod 0600 "$KEY"
  PUBKEY_PEM=$(openssl rsa -in "$KEY" -pubout 2>/dev/null)
  PUBKEY_B64=$(printf '%s' "$PUBKEY_PEM" | sed '/-----/d' | tr -d '\n')

  NORM_URL=$(python3 -c "
import sys
from urllib.parse import urlparse
raw = sys.argv[1].strip().rstrip('/')
if '://' not in raw:
    raw = 'https://' + raw
u = urlparse(raw)
host = u.hostname
if not host:
    sys.exit(f'cannot parse host from {sys.argv[1]!r}')
port = u.port
scheme = u.scheme or 'https'
print(f'{scheme}://{host}' + ('' if port in (None, 443) else f':{port}'))
" "$domain")
  TOKEN_URL="${NORM_URL}/oauth2/v1/token"
  echo "diag: OCI domain fingerprint=$(printf '%s' "$NORM_URL" | sha256sum | head -c 12)"

  HTTP_CODE=$(curl -sS -o /tmp/oci_resp.json -w "%{http_code}" -X POST "${TOKEN_URL}" \
    -H 'Content-Type: application/x-www-form-urlencoded' \
    -u "${client}" \
    --data-urlencode "grant_type=urn:ietf:params:oauth:grant-type:token-exchange" \
    --data-urlencode "requested_token_type=urn:oci:token-type:oci-upst" \
    --data-urlencode "subject_token=${GH_JWT}" \
    --data-urlencode "subject_token_type=jwt" \
    --data-urlencode "public_key=${PUBKEY_B64}")
  echo "diag: OCI token exchange HTTP $HTTP_CODE"
  if [[ "$HTTP_CODE" != "200" ]]; then
    echo "::error::OCI profile $profile token exchange returned HTTP $HTTP_CODE"
    cat /tmp/oci_resp.json
    exit 1
  fi

  TOKEN=$(jq -r '.token // .access_token // empty' /tmp/oci_resp.json)
  if [[ -z "$TOKEN" ]]; then
    echo "::error::OCI profile $profile token exchange returned no token"
    head -c 500 /tmp/oci_resp.json
    exit 1
  fi
  printf '%s' "$TOKEN" > "$UPST"
  chmod 0600 "$UPST"

  # OCI provider's SecurityToken auth path requires `fingerprint` even
  # though the token carries auth. Compute MD5 fingerprint of the public
  # key in DER form (format: aa:bb:cc:...).
  FINGERPRINT=$(openssl rsa -in "$KEY" -pubout -outform DER 2>/dev/null | openssl dgst -md5 -c 2>/dev/null | awk '{print $NF}')

  cat >> "$HOME/.oci/config" <<CFG

[${profile}]
auth = security_token
security_token_file = ${UPST}
key_file = ${KEY}
fingerprint = ${FINGERPRINT}
tenancy = ${tenancy}
region = ${region}
CFG

  chmod 0600 "$HOME/.oci/config"

  echo "wrote ~/.oci/config profile [$profile]"
  echo "::endgroup::"
done
