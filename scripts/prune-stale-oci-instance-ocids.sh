#!/usr/bin/env bash
# Download every production/inventory/oracle/*/nodes.yaml from R2, remove
# node.provider_data.oci_instance_ocid, and upload back. Leaves every
# other field intact. Used when imports.tf points at an OCI instance OCID
# that no longer exists in OCI, which makes tofu plan fail with:
#   Cannot import non-existent remote object
# The script is intentionally broad — every oracle nodes.yaml is
# rewritten, not just ones that reference missing instances. Tofu then
# treats the instance as unmanaged on the next plan, CreateInstance
# runs, and the state-writer repopulates OCIDs on apply success.
#
# Requires: aws CLI, python3 with PyYAML. Reads R2 creds from env
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY / R2_ENDPOINT.
set -euo pipefail

: "${AWS_ACCESS_KEY_ID:?set}"
: "${AWS_SECRET_ACCESS_KEY:?set}"
: "${R2_ENDPOINT:?set}"

src=$(mktemp -d)
aws s3 sync "s3://cluster-tofu-state/production/inventory/oracle/" "$src/" \
  --endpoint-url "$R2_ENDPOINT" --region us-east-1 \
  --exclude "*" --include "*/nodes.yaml" || true

shopt -s nullglob
any=false
for f in "$src"/*/nodes.yaml; do
  acct=$(basename "$(dirname "$f")")
  python3 "$(dirname "$0")/prune_stale_oci_instance_ocids.py" "$f"
  KEY="production/inventory/oracle/${acct}/nodes.yaml"
  aws s3 cp "$f" "s3://cluster-tofu-state/${KEY}" \
    --endpoint-url "$R2_ENDPOINT" --region us-east-1
  echo "::notice::wrote $KEY"
  any=true
done

if [[ "$any" != "true" ]]; then
  echo "::notice::no oracle nodes.yaml files in R2 — nothing to prune"
fi
