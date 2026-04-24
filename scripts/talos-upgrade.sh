#!/usr/bin/env bash
# Runs `talosctl upgrade --preserve` against a single node, waits for the
# Talos API to come back up, then verifies the installed version matches
# $EXPECT_VERSION (defaults to the tag portion of $IMAGE).
#
# Required env: NODE, TALOSCONFIG, IMAGE
# Optional env: EXPECT_VERSION, STAGE (set to "true" to pass --stage),
#               MAX_WAIT_SECONDS (default 600 = 10 minutes)
set -euo pipefail

: "${NODE:?NODE is required}"
: "${TALOSCONFIG:?TALOSCONFIG is required}"
: "${IMAGE:?IMAGE is required}"

EXPECT_VERSION="${EXPECT_VERSION:-${IMAGE##*:}}"
MAX_WAIT_SECONDS="${MAX_WAIT_SECONDS:-600}"
STAGE_ARG=()
if [[ "${STAGE:-false}" == "true" ]]; then
  STAGE_ARG=(--stage)
fi

echo "[talos-upgrade] node=$NODE image=$IMAGE expect=$EXPECT_VERSION"

talosctl \
  --talosconfig "$TALOSCONFIG" \
  upgrade \
  "${STAGE_ARG[@]}" \
  --preserve \
  --image="$IMAGE" \
  --nodes="$NODE"

# Poll up to MAX_WAIT_SECONDS for API to return a matching version.
attempts=$(( MAX_WAIT_SECONDS / 10 ))
for _ in $(seq 1 "$attempts"); do
  if OUT=$(talosctl --talosconfig "$TALOSCONFIG" version --nodes "$NODE" 2>/dev/null); then
    CUR=$(echo "$OUT" | awk '/^[[:space:]]*Tag:/ {print $2; exit}')
    if [[ "$CUR" == "$EXPECT_VERSION" ]]; then
      echo "[talos-upgrade] success (tag=$CUR)"
      exit 0
    fi
  fi
  sleep 10
done

echo "[talos-upgrade] version mismatch after ${MAX_WAIT_SECONDS}s: wanted $EXPECT_VERSION, got ${CUR:-unknown}" >&2
exit 1
