#!/usr/bin/env bash
# Fails if any per-layer sops-check.tf differs from the shared template.
# Catches hand-edits to generated files before they are committed.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
SRC="$ROOT/tofu/shared/sops-check.tf.tmpl"
LAYERS=(
  tofu/layers/00-talos-secrets
  tofu/layers/01-contabo-infra
  tofu/layers/02-oracle-infra
  tofu/layers/02-onprem-infra
  tofu/layers/03-talos
)

drift=()
for layer in "${LAYERS[@]}"; do
  dest="$ROOT/$layer/sops-check.tf"
  if [[ -f "$dest" ]] && ! diff -q "$SRC" "$dest" > /dev/null 2>&1; then
    drift+=("$layer/sops-check.tf")
  fi
done

if [[ ${#drift[@]} -gt 0 ]]; then
  echo "ERROR: per-layer sops-check.tf has drifted from template." >&2
  for f in "${drift[@]}"; do
    echo "  $f" >&2
  done
  echo "Run scripts/sync-sops-check.sh and commit the result." >&2
  exit 1
fi
