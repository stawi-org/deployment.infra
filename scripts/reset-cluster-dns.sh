#!/usr/bin/env bash
# Delete every DNS record on the cluster's Cloudflare zones whose name
# starts with "cp", "cp-", or equals "prod". Pairs with the cluster_dns
# module in layer 03 — when that module first runs after the legacy
# layer-01 DNS was removed, Cloudflare rejects CreateRecord with
# "identical record already exists" because the old records are still
# in CF but no longer in any tofu state. Running this once clears them
# so the module can create them fresh under its own management.
#
# Zones + zone_ids are hardcoded from tofu/layers/03-talos/terraform.tfvars.
# If that list grows, update ZONES below.
#
# Env: CF_API_TOKEN (Zone:DNS:Edit on every zone).
set -euo pipefail

: "${CF_API_TOKEN:?set CF_API_TOKEN}"

# name => zone_id
declare -A ZONES=(
  [antinvestor.com]=e5a43681579acad9c15657ac21dbd66a
  [stawi.org]=706bf604a333d866bb38c03bf643e79a
)

any_deleted=false
for zone in "${!ZONES[@]}"; do
  zid="${ZONES[$zone]}"
  echo "Scanning $zone ($zid)…"

  # Cloudflare returns all records for the zone. We then filter locally
  # by name prefix. Paginate just in case; default per_page=100 is plenty
  # for a cluster this size but request 1000 to be safe.
  resp=$(curl -fsSL \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records?per_page=1000")

  ok=$(jq -r '.success' <<<"$resp")
  if [[ "$ok" != "true" ]]; then
    echo "::error::list failed for $zone"
    jq '.errors' <<<"$resp" >&2
    exit 1
  fi

  # Match: name == "cp.$zone" OR name starts with "cp-" OR name == "prod.$zone"
  matches=$(jq -r --arg zone "$zone" '
    .result[]
    | select(
        (.name == ("cp." + $zone))
        or (.name | startswith("cp-"))
        or (.name == ("prod." + $zone))
      )
    | "\(.id)\t\(.name)\t\(.type)\t\(.content)"
  ' <<<"$resp")

  if [[ -z "$matches" ]]; then
    echo "  no matching records"
    continue
  fi

  while IFS=$'\t' read -r rid rname rtype rcontent; do
    echo "  deleting $rtype $rname → $rcontent ($rid)"
    dresp=$(curl -fsSL -X DELETE \
      -H "Authorization: Bearer $CF_API_TOKEN" \
      "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records/${rid}")
    dok=$(jq -r '.success' <<<"$dresp")
    if [[ "$dok" != "true" ]]; then
      echo "::error::delete failed for $rid on $zone"
      jq '.errors' <<<"$dresp" >&2
      exit 1
    fi
    any_deleted=true
  done <<<"$matches"
done

if [[ "$any_deleted" == "true" ]]; then
  echo "::notice::orphaned cluster DNS records deleted"
else
  echo "::notice::nothing to delete"
fi
