#!/usr/bin/env bash
# scripts/migrate-auth-to-repo.sh
#
# One-shot helper: copy every provider/account auth.yaml from R2, then
# re-encrypt every file with the repo's .sops.yaml rule and drop the
# result in tofu/shared/accounts/<provider>/<account>/auth.yaml.
#
# Contabo accounts were removed (fleet cut off). Providers: oracle,
# onprem, gcp.
#
# Prereqs (env):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  — R2 bucket creds
#   R2_ACCOUNT_ID                              — endpoint hostname slug
#   SOPS_AGE_KEY                               — private age key
# Required tools on PATH: aws, sops, yq
#
# Run from the repo root.
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?required}"
: "${AWS_SECRET_ACCESS_KEY:?required}"
: "${R2_ACCOUNT_ID:?required}"
: "${SOPS_AGE_KEY:?required}"

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
[[ -f .sops.yaml ]] || { echo ".sops.yaml not at repo root — aborting" >&2; exit 1; }

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
BUCKET="cluster-tofu-state"

for prov in oracle onprem gcp; do
  mapfile -t accts < <(yq -r ".${prov}[]?" tofu/shared/accounts.yaml)
  for acct in "${accts[@]}"; do
    [[ -z "$acct" ]] && continue
    key="production/inventory/${prov}/${acct}/auth.yaml"
    dest="tofu/shared/accounts/${prov}/${acct}/auth.yaml"
    mkdir -p "$(dirname "$dest")"
    tmp=$(mktemp)
    echo "[$prov/$acct] pulling s3://$BUCKET/$key"
    if ! aws s3 cp "s3://${BUCKET}/${key}" "$tmp" \
        --endpoint-url "$ENDPOINT" --region us-east-1 2>/dev/null; then
      echo "  no auth.yaml in R2 for $prov/$acct — skipping"
      rm -f "$tmp"
      continue
    fi
    cp "$tmp" "$dest"
    rm -f "$tmp"
    sops -e --input-type yaml --output-type yaml -i "$dest"
    echo "  wrote encrypted $dest"
  done
done

echo "Done. Inspect git status and commit."
