#!/usr/bin/env bash
# Copies tofu/shared/sops-check.tf.tmpl into every layer as sops-check.tf.
# Run via pre-commit; also safe to run manually.
set -euo pipefail

SRC="$(git rev-parse --show-toplevel)/tofu/shared/sops-check.tf.tmpl"
LAYERS=(
  tofu/layers/00-talos-secrets
  tofu/layers/01-contabo-infra
  tofu/layers/02-oracle-infra
  tofu/layers/02-onprem-infra
  tofu/layers/03-talos
)

root="$(git rev-parse --show-toplevel)"
for layer in "${LAYERS[@]}"; do
  cp "$SRC" "$root/$layer/sops-check.tf"
done
