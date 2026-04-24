#!/usr/bin/env bash
# Delete transitional files under production/inventory/ that are not
# part of the agreed layout:
#   - state.yaml             (merged into nodes.yaml.provider_data)
#   - talos-state.yaml       (dropped; tfstate owns applied-version tracking)
#   - machine-configs.yaml   (replaced by <talos-version>/<node>.yaml)
#
# Idempotent: a re-run after cleanup deletes nothing (s3 rm on a
# non-existent key is a no-op with the CLI's warning suppressed).
#
# Requires: aws CLI with R2 creds (AWS_ACCESS_KEY_ID/_SECRET + R2_ENDPOINT).
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?set}"
: "${AWS_SECRET_ACCESS_KEY:?set}"
: "${R2_ENDPOINT:?set}"

BUCKET="cluster-tofu-state"
PREFIX="production/inventory"

echo "listing $PREFIX on $R2_ENDPOINT/$BUCKET"
mapfile -t KEYS < <(
  aws s3api list-objects-v2 \
    --endpoint-url "$R2_ENDPOINT" --region us-east-1 \
    --bucket "$BUCKET" --prefix "$PREFIX/" \
    --query 'Contents[].Key' --output text 2>/dev/null \
    | tr '\t' '\n' \
    | awk '
        /\/state\.yaml$/
        /\/talos-state\.yaml$/
        /\/machine-configs\.yaml$/
      '
)

if [[ ${#KEYS[@]} -eq 0 ]]; then
  echo "::notice::no legacy files to delete — bucket already matches agreed layout"
  exit 0
fi

for k in "${KEYS[@]}"; do
  echo "  rm s3://$BUCKET/$k"
  aws s3 rm "s3://$BUCKET/$k" --endpoint-url "$R2_ENDPOINT" --region us-east-1
done
echo "::notice::deleted ${#KEYS[@]} legacy file(s)"
