#!/usr/bin/env bash
#
# tofu/layers/03-talos/scripts/sync-machine-label.sh
#
# Per-machine reconciler. Called by null_resource.omnictl_machine_label
# in cluster.tf, once per node (via for_each). Polls Omni's
# machinestatus inventory up to REGISTRATION_TIMEOUT_SECS waiting for
# the target node to register, then applies a MachineLabels.omni.sidero.dev
# resource with the per-node labels passed in via env.
#
# Inputs (env):
#   NODE_NAME              Hostname of the target node (e.g. oci-bwire-node-1).
#   NODE_LABELS_JSON       Compact JSON object of labels to apply.
#                          Empty/null/{} is a documented no-op.
#   NODE_IPV4              IPv4 of the target node. Used as a fallback
#                          match against Omni's spec.network.addresses
#                          when hostname doesn't match (Contabo case).
#                          Empty string is OK; IPv4 match is skipped.
#   NODE_OMNI_MACHINE_ID   Optional preferred Omni Machine UUID from
#                          inventory provider_data.omni_machine_id. When
#                          set and still present in Omni (and connected,
#                          or no connected hostname twin), matching uses
#                          this id first — avoids twin-UUID thrash.
#   OMNI_ENDPOINT          omnictl reads this.
#   OMNI_SERVICE_ACCOUNT_KEY omnictl reads this.
#   OMNI_CLUSTER           Cluster name (used in log lines).
#   REGISTRATION_TIMEOUT_SECS (default 900) — poll wait for registration.
#   REGISTRATION_POLL_SECS   (default 15) — poll interval.
#
# Behaviour:
#   - Idempotent: `omnictl apply` upserts MachineLabels, so re-running
#     with same content is a no-op apply.
#   - Empty NODE_LABELS_JSON or {} → log + exit 0 (no-op).
#   - Poll-timeout (target not registered in time) → log WARN, exit 0.
#     Operator triggers a retry by bumping label_sync_retry_token.
#   - omnictl apply non-zero → log ERROR, exit non-zero (so tofu
#     marks this one instance's creation failed, and the next apply
#     retries this one instance only).
#
# Machine match priority (scripts/lib/omni_machine_match.py):
#   preferred_id → hostname (prefer connected) → ipv4 (prefer connected)

set -euo pipefail

[[ -n "${NODE_NAME:-}" ]] || { echo "[sync-machine-label] NODE_NAME not set" >&2; exit 1; }
[[ -n "${NODE_LABELS_JSON:-}" ]] || { echo "[sync-machine-label] NODE_LABELS_JSON not set" >&2; exit 1; }
[[ -n "${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "[sync-machine-label] OMNI_SERVICE_ACCOUNT_KEY unset" >&2; exit 1; }
command -v omnictl >/dev/null || { echo "[sync-machine-label] omnictl not in PATH" >&2; exit 1; }
command -v jq      >/dev/null || { echo "[sync-machine-label] jq not in PATH"      >&2; exit 1; }
command -v python3 >/dev/null || { echo "[sync-machine-label] python3 not in PATH" >&2; exit 1; }

readonly NODE_IPV4_VAL="${NODE_IPV4:-}"
readonly NODE_OMNI_MACHINE_ID_VAL="${NODE_OMNI_MACHINE_ID:-}"
readonly REGISTRATION_TIMEOUT_SECS="${REGISTRATION_TIMEOUT_SECS:-900}"
readonly REGISTRATION_POLL_SECS="${REGISTRATION_POLL_SECS:-15}"

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# tofu/layers/03-talos/scripts → repo root
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd)
MATCH_PY="$REPO_ROOT/scripts/lib/omni_machine_match.py"
[[ -f "$MATCH_PY" ]] || { echo "[sync-machine-label] missing $MATCH_PY" >&2; exit 1; }

# Validate the labels JSON parses, and short-circuit on empty.
if ! jq -e . >/dev/null 2>&1 <<<"$NODE_LABELS_JSON"; then
  echo "[sync-machine-label] $NODE_NAME: NODE_LABELS_JSON is not valid JSON — aborting" >&2
  exit 1
fi
label_count=$(jq -r 'length' <<<"$NODE_LABELS_JSON")
if [[ "$label_count" == "0" ]]; then
  echo "[sync-machine-label] $NODE_NAME: no labels to apply (empty map), exiting"
  exit 0
fi

# Fetch one snapshot of Omni machine inventory. NDJSON → array.
fetch_machines() {
  local result
  result=$(omnictl get machinestatus --output json 2>/dev/null | jq -cs 'flatten' 2>/dev/null) || result=''
  if [[ -z "$result" ]] || ! jq -e . >/dev/null 2>&1 <<<"$result"; then
    result='[]'
  fi
  printf '%s' "$result"
}

match_machine_id() {
  local machines_json="$1"
  local ms_file
  ms_file=$(mktemp -t omni-ms-XXXXXX.json)
  printf '%s' "$machines_json" >"$ms_file"
  python3 "$MATCH_PY" \
    --machines-file "$ms_file" \
    --preferred-id "$NODE_OMNI_MACHINE_ID_VAL" \
    --hostname "$NODE_NAME" \
    --ipv4 "$NODE_IPV4_VAL" \
    --print-reason
  rm -f "$ms_file"
}

deadline=$(( $(date +%s) + REGISTRATION_TIMEOUT_SECS ))
machine_id=""
match_reason=""

while :; do
  machines_arr=$(fetch_machines)
  # match prints "id\treason" or "\treason"
  match_line=$(match_machine_id "$machines_arr" || true)
  machine_id="${match_line%%$'\t'*}"
  match_reason="${match_line#*$'\t'}"
  if [[ -n "$machine_id" ]]; then
    echo "[sync-machine-label] $NODE_NAME: matched machine id=$machine_id reason=$match_reason"
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "[sync-machine-label] WARN $NODE_NAME (ipv4=$NODE_IPV4_VAL preferred=${NODE_OMNI_MACHINE_ID_VAL:-none}): registration wait timed out after ${REGISTRATION_TIMEOUT_SECS}s — skipping"
    exit 0
  fi
  echo "[sync-machine-label] $NODE_NAME: not yet registered, polling again in ${REGISTRATION_POLL_SECS}s"
  sleep "$REGISTRATION_POLL_SECS"
done

# Render and apply the MachineLabels resource. Labels live in
# metadata.labels (COSI-style); MachineLabelsSpec is empty.
manifest=$(jq -n \
  --arg id "$machine_id" \
  --argjson labels "$NODE_LABELS_JSON" '{
    metadata: {
      namespace: "default",
      type:      "MachineLabels.omni.sidero.dev",
      id:        $id,
      labels:    $labels,
    },
    spec: {},
  }')
manifest_file=$(mktemp -t "machinelabels-${machine_id}.XXXXXX.json")
trap 'rm -f "$manifest_file"' EXIT
printf '%s\n' "$manifest" > "$manifest_file"

echo "[sync-machine-label] $NODE_NAME: applying $label_count label(s) to machine $machine_id"
if omnictl apply -f "$manifest_file" 2>&1 | sed 's/^/  /'; then
  echo "[sync-machine-label] $NODE_NAME: done"
  exit 0
else
  echo "[sync-machine-label] ERROR $NODE_NAME: omnictl apply MachineLabels failed" >&2
  exit 1
fi
