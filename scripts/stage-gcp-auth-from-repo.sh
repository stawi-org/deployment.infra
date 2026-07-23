#!/usr/bin/env bash
# Decrypt repo-resident gcp auth.yaml files into:
#   <out>/<account>/auth.yaml  (plaintext)
#
# Usage: scripts/stage-gcp-auth-from-repo.sh [OUT_DIR] [REPO_ROOT]
set -euo pipefail

OUT="${1:-/tmp/gcp-auth-from-repo}"
ROOT="${2:-.}"
ROOT="$(cd "$ROOT" && pwd)"

command -v sops >/dev/null 2>&1 || { echo "missing: sops" >&2; exit 2; }

rm -rf "$OUT"
mkdir -p "$OUT"

shopt -s nullglob
count=0
for f in "$ROOT"/tofu/shared/accounts/gcp/*/auth.yaml; do
  acct=$(basename "$(dirname "$f")")
  mkdir -p "$OUT/$acct"
  if ! sops -d --input-type yaml --output-type yaml "$f" > "$OUT/$acct/auth.yaml"; then
    echo "::error::failed to decrypt $f" >&2
    exit 1
  fi
  count=$((count + 1))
done

echo "::notice::staged ${count} gcp auth.yaml file(s) from repo into ${OUT}" >&2
printf '%s\n' "$OUT"
