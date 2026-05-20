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

set -euo pipefail

[[ -n "${NODE_NAME:-}" ]] || { echo "[sync-machine-label] NODE_NAME not set" >&2; exit 1; }
[[ -n "${NODE_LABELS_JSON:-}" ]] || { echo "[sync-machine-label] NODE_LABELS_JSON not set" >&2; exit 1; }
[[ -n "${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "[sync-machine-label] OMNI_SERVICE_ACCOUNT_KEY unset" >&2; exit 1; }
command -v omnictl >/dev/null || { echo "[sync-machine-label] omnictl not in PATH" >&2; exit 1; }
command -v jq      >/dev/null || { echo "[sync-machine-label] jq not in PATH"      >&2; exit 1; }

readonly NODE_IPV4_VAL="${NODE_IPV4:-}"
readonly REGISTRATION_TIMEOUT_SECS="${REGISTRATION_TIMEOUT_SECS:-900}"
readonly REGISTRATION_POLL_SECS="${REGISTRATION_POLL_SECS:-15}"

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
# Hardened against transient non-JSON output from omnictl (same shape
# as the prior bulk script).
fetch_machines() {
  local result
  result=$(omnictl get machinestatus --output json 2>/dev/null | jq -cs 'flatten' 2>/dev/null) || result=''
  if [[ -z "$result" ]] || ! jq -e . >/dev/null 2>&1 <<<"$result"; then
    result='[]'
  fi
  printf '%s' "$result"
}

# Match this one node to a machine ID. Hostname is the primary key
# (Omni picks up the platform hostname for OCI); IPv4 fallback covers
# Contabo where the platform hostname is the system UUID.
machine_id_for() {
  local machines_json="$1"
  jq -r --arg n "$NODE_NAME" --arg ip "$NODE_IPV4_VAL" '
    [
      (.[] | select((.spec.network.hostname // "") == $n) | .metadata.id),
      (.[] | select(
        ($ip != "") and (
          any(.spec.network.addresses // [] | .[]; (split("/")[0]) == $ip)
        )
      ) | .metadata.id)
    ] | .[0] // ""
  ' <<<"$machines_json"
}

deadline=$(( $(date +%s) + REGISTRATION_TIMEOUT_SECS ))
machine_id=""

while :; do
  machines_arr=$(fetch_machines)
  machine_id=$(machine_id_for "$machines_arr")
  if [[ -n "$machine_id" ]]; then
    echo "[sync-machine-label] $NODE_NAME: matched machine id=$machine_id"
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "[sync-machine-label] WARN $NODE_NAME (ipv4=$NODE_IPV4_VAL): registration wait timed out after ${REGISTRATION_TIMEOUT_SECS}s — skipping"
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
