#!/usr/bin/env bash
# scripts/get-talos-configs.sh
#
# Fetches the latest published Talos machine-config bundle from the
# publish-talos-configs workflow. Unpacks into ./talos-configs/ so you
# can read the files locally or feed generic-worker.yaml into
# `talosctl apply-config` on a new node.
#
# Usage:
#   ./scripts/get-talos-configs.sh               # Fetch latest successful run
#   ./scripts/get-talos-configs.sh --refresh     # Dispatch a fresh publish run first
#   ./scripts/get-talos-configs.sh --out /tmp/tc # Pick a different output dir
#
# Requirements:
#   - gh CLI authed against antinvestor/deployments
#   - jq
#
# The bundle is NOT encrypted — machine configs contain cluster secrets
# (Talos CA, bootstrap token, etcd keys) but the artifact is only
# readable by GitHub users who already have repo access. Treat the
# downloaded files with the same sensitivity you would a kubeconfig.

set -euo pipefail

OUT="./talos-configs"
REFRESH=false
REPO="antinvestor/deployments"
WORKFLOW="publish-talos-configs.yml"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)     OUT="$2"; shift 2 ;;
    --refresh) REFRESH=true; shift ;;
    --repo)    REPO="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

for cmd in gh jq ; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 2; }
done

say() { printf '\e[1;34m[%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$*" ; }

if $REFRESH ; then
  say "Dispatching $WORKFLOW..."
  gh workflow run "$WORKFLOW" --ref main -R "$REPO" >/dev/null
  # Poll briefly for the new run to appear.
  RUN_ID=""
  for _ in $(seq 1 20) ; do
    RUN_ID=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId,status \
      --jq '.[] | select(.status=="queued" or .status=="in_progress") | .databaseId' 2>/dev/null | head -1 || true)
    [[ -n "$RUN_ID" ]] && break
    sleep 2
  done
  [[ -n "$RUN_ID" ]] || { echo "Could not find dispatched run." >&2; exit 1; }
  say "Waiting for run $RUN_ID..."
  gh run watch "$RUN_ID" -R "$REPO" --exit-status >/dev/null
else
  # Use the latest successful run of the publish workflow (from any trigger,
  # including the automatic post-apply call).
  RUN_ID=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --limit 10 \
    --json databaseId,conclusion,status \
    --jq '.[] | select(.conclusion=="success") | .databaseId' | head -1)
  [[ -n "$RUN_ID" ]] || { echo "No successful $WORKFLOW run found. Retry with --refresh." >&2; exit 1; }
  say "Using latest successful run: $RUN_ID"
fi

say "Downloading talos-configs artifact to $OUT/..."
mkdir -p "$OUT"
gh run download "$RUN_ID" -R "$REPO" -n talos-configs -D "$OUT" >/dev/null

say "Done. Contents:"
find "$OUT" -maxdepth 2 -type f | sed 's|^|  |'
echo ""
say "See $OUT/README.md for how to join a non-cloud machine."
