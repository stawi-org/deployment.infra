#!/usr/bin/env bash
# Apply a JSON { "<old_key>": "<new_key>", ... } mapping to every
# R2 inventory file. For each (provider, account) directory:
#
#   nodes.yaml            .nodes[<old>] renamed to .nodes[<new>]
#   <version>/<old>.yaml  copy to <version>/<new>.yaml, delete old key
#
# Idempotent — after the first pass the old keys are gone.
#
# Requires: aws CLI, python3 + PyYAML, R2 creds, MAPPING_JSON env var.
set -euo pipefail

: "${MAPPING_JSON:?set MAPPING_JSON}"
: "${AWS_ACCESS_KEY_ID:?set}"
: "${AWS_SECRET_ACCESS_KEY:?set}"
: "${R2_ENDPOINT:?set}"

BUCKET="cluster-tofu-state"

# Validate JSON up front so a typo fails before we touch R2.
python3 -c "import json,sys; json.loads(sys.argv[1])" "$MAPPING_JSON" \
  || { echo "::error::mapping_json is not valid JSON"; exit 1; }

# Stage every inventory file locally so we can edit/upload atomically
# per-file.
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
aws s3 sync "s3://${BUCKET}/production/inventory/" "$staging/" \
  --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null

any_changed=false

shopt -s nullglob

# ---------- Pass 1: rewrite nodes.yaml ------------------------------
for f in "$staging"/*/*/nodes.yaml; do
  out=$(python3 scripts/rename_inventory_keys.py "$f" "$MAPPING_JSON")
  if [[ "$out" = "changed" ]]; then
    rel="${f#$staging/}"
    key="production/inventory/${rel}"
    aws s3 cp "$f" "s3://${BUCKET}/${key}" \
      --endpoint-url "$R2_ENDPOINT" --region us-east-1
    echo "::notice::rewrote ${key}"
    any_changed=true
  fi
done

# ---------- Pass 2: rename <version>/<old>.yaml → <version>/<new>.yaml --
python3 -c '
import json, os, sys
m = json.loads(os.environ["MAPPING_JSON"])
sys.stdout.write("\n".join(f"{k}\t{v}" for k, v in m.items()))
' > "$staging/.mapping.tsv"

while IFS=$'\t' read -r old new; do
  [[ -n "$old" && -n "$new" && "$old" != "$new" ]] || continue
  for old_obj in "$staging"/*/*/*/"${old}.yaml"; do
    [[ -e "$old_obj" ]] || continue
    new_obj="$(dirname "$old_obj")/${new}.yaml"
    old_rel="${old_obj#$staging/}"
    new_rel="${new_obj#$staging/}"
    old_key="production/inventory/${old_rel}"
    new_key="production/inventory/${new_rel}"
    aws s3 cp "s3://${BUCKET}/${old_key}" "s3://${BUCKET}/${new_key}" \
      --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null
    aws s3 rm "s3://${BUCKET}/${old_key}" \
      --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null
    echo "::notice::renamed ${old_key} → ${new_key}"
    any_changed=true
  done
done < "$staging/.mapping.tsv"

if [[ "$any_changed" != "true" ]]; then
  echo "::notice::no keys matched the mapping — bucket unchanged"
fi
