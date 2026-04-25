#!/usr/bin/env bash
# Rename account directories under production/inventory/ in R2.
#
# Takes a JSON mapping of { "<provider>/<old_acct>": "<provider>/<new_acct>" }
# and moves every object from the old prefix to the new one, then
# deletes the old objects. Idempotent — after the first successful run
# there are no objects under the old prefixes, so a second run is a
# no-op.
#
# Pair this with scripts/rename-inventory-keys.sh to rewrite node_keys
# *inside* the moved files. Correct order is:
#   1. rename-inventory-accounts  (move <prov>/<old>/ to <prov>/<new>/)
#   2. rename-inventory-keys      (update .nodes[] keys + rename
#                                  <version>/<node>.yaml files)
#
# Requires: aws CLI, MAPPING_JSON env var, R2 creds.
set -euo pipefail

: "${MAPPING_JSON:?set MAPPING_JSON}"
: "${AWS_ACCESS_KEY_ID:?set}"
: "${AWS_SECRET_ACCESS_KEY:?set}"
: "${R2_ENDPOINT:?set}"

BUCKET="cluster-tofu-state"
PREFIX="production/inventory"

python3 -c "import json,sys; json.loads(sys.argv[1])" "$MAPPING_JSON" \
  || { echo "::error::mapping_json is not valid JSON"; exit 1; }

# Emit "<old>\t<new>" lines from the mapping so we can read with IFS=$'\t'.
mapping_tsv=$(python3 -c '
import json, os, sys
m = json.loads(os.environ["MAPPING_JSON"])
for k, v in m.items():
    if k == v:
        continue
    print(f"{k}\t{v}")
' )

any_changed=false
while IFS=$'\t' read -r old new; do
  [[ -n "$old" && -n "$new" ]] || continue
  echo "::group::$old → $new"
  old_prefix="${PREFIX}/${old}/"
  new_prefix="${PREFIX}/${new}/"

  # List keys under the OLD prefix. If empty, skip — already renamed or
  # never existed.
  mapfile -t old_keys < <(
    aws s3api list-objects-v2 \
      --bucket "$BUCKET" --prefix "$old_prefix" \
      --endpoint-url "$R2_ENDPOINT" --region us-east-1 \
      --query 'Contents[].Key' --output text 2>/dev/null | tr '\t' '\n' | grep -v '^None$' || true
  )
  if [[ ${#old_keys[@]} -eq 0 ]]; then
    echo "::notice::nothing under $old_prefix — skipping"
    echo "::endgroup::"
    continue
  fi

  for key in "${old_keys[@]}"; do
    [[ -n "$key" ]] || continue
    rel="${key#$old_prefix}"
    new_key="${new_prefix}${rel}"
    aws s3 cp "s3://${BUCKET}/${key}" "s3://${BUCKET}/${new_key}" \
      --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null
    aws s3 rm "s3://${BUCKET}/${key}" \
      --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null
    echo "::notice::moved ${key} → ${new_key}"
    any_changed=true
  done
  echo "::endgroup::"
done <<< "$mapping_tsv"

if [[ "$any_changed" != "true" ]]; then
  echo "::notice::no accounts matched the mapping — bucket unchanged"
fi
