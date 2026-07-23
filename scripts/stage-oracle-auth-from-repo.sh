#!/usr/bin/env bash
# Decrypt repo-resident oracle auth.yaml files into a staging directory
# shaped like the legacy R2 inventory tree:
#   <out>/<account>/auth.yaml  (plaintext)
#
# Used by CI (tofu-layer WIF, sync-talos-images discover) so new accounts
# onboarded only via tofu/shared/accounts/oracle/<acct>/auth.yaml work
# without a parallel R2 auth upload.
#
# Usage:
#   scripts/stage-oracle-auth-from-repo.sh [OUT_DIR] [REPO_ROOT]
#
# Requires: sops on PATH, and SOPS_AGE_KEY / SOPS_AGE_KEY_FILE / age keys.
set -euo pipefail

OUT="${1:-/tmp/oracle-auth-from-repo}"
ROOT="${2:-.}"
ROOT="$(cd "$ROOT" && pwd)"

command -v sops >/dev/null 2>&1 || { echo "missing: sops" >&2; exit 2; }

rm -rf "$OUT"
mkdir -p "$OUT"

shopt -s nullglob
count=0
for f in "$ROOT"/tofu/shared/accounts/oracle/*/auth.yaml; do
  acct=$(basename "$(dirname "$f")")
  mkdir -p "$OUT/$acct"
  if ! sops -d --input-type yaml --output-type yaml "$f" > "$OUT/$acct/auth.yaml"; then
    echo "::error::failed to decrypt $f" >&2
    exit 1
  fi
  count=$((count + 1))
done

echo "::notice::staged ${count} oracle auth.yaml file(s) from repo into ${OUT}" >&2
printf '%s\n' "$OUT"
