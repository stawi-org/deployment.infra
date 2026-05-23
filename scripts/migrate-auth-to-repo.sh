#!/usr/bin/env bash
# scripts/migrate-auth-to-repo.sh
#
# One-shot helper: copy every provider/account auth.yaml from R2, decrypt
# the contabo entries (they were age-encrypted at rest in R2), then re-
# encrypt every file with the repo's .sops.yaml rule and drop the result
# in tofu/shared/accounts/<provider>/<account>/auth.yaml.
#
# After M2 lands (which flips tofu's auth read path to the repo path),
# this script becomes obsolete and is removed in PR M3 alongside the R2
# auth.yaml cleanup workflow.
#
# Prereqs (env):
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY  — R2 bucket creds
#   R2_ACCOUNT_ID                              — endpoint hostname slug
#   SOPS_AGE_KEY                               — private age key (needed to
#                                                decrypt the existing
#                                                R2-encrypted contabo auth)
# Required tools on PATH: aws, sops, yq
#
# Run from the repo root.
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?required}"
: "${AWS_SECRET_ACCESS_KEY:?required}"
: "${R2_ACCOUNT_ID:?required}"
: "${SOPS_AGE_KEY:?required (used to decrypt existing R2 contabo auth)}"

REPO_ROOT=$(git rev-parse --show-toplevel)
cd "$REPO_ROOT"
[[ -f .sops.yaml ]] || { echo ".sops.yaml not at repo root — aborting" >&2; exit 1; }

ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
BUCKET="cluster-tofu-state"

for prov in contabo oracle onprem; do
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
    if [[ "$prov" == "contabo" ]]; then
      sops -d --input-type yaml --output-type yaml "$tmp" > "$dest"
    else
      cp "$tmp" "$dest"
    fi
    rm -f "$tmp"
    sops -e --input-type yaml --output-type yaml -i "$dest"
    echo "  wrote encrypted $dest"
  done
done

echo "Done. Inspect git status and commit."
