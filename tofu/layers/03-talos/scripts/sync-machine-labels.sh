#!/usr/bin/env bash
#
# tofu/layers/03-talos/scripts/sync-machine-labels.sh
#
# Idempotent reconciler that copies tofu's per-node `derived_labels`
# onto each registered Omni Machine. Called from cluster.tf's
# null_resource.omnictl_machine_labels.
#
# Inputs:
#   $1                       Path to JSON file mapping
#                            <node_name> → { <label_k>: <label_v>, ... }
#   $OMNI_CLUSTER            Cluster name (filters Omni machines we touch).
#   $OMNI_ENDPOINT           Set in caller env; omnictl reads it.
#   $OMNI_SERVICE_ACCOUNT_KEY Set in caller env; omnictl reads it.
#
# Behaviour:
#   - Fetches all Omni MachineStatuses, builds a hostname → machine-id map.
#   - For each (node_name, labels) pair in the JSON, finds the matching
#     machine (by `spec.network.hostname`) and runs:
#       omnictl machine update <id> --user-label k=v [--user-label k=v ...]
#   - Nodes not yet registered with Omni warn-and-skip (transient — the
#     next apply picks them up).
#   - Empty input file is a no-op.
#
# Exits non-zero only on systemic errors (missing JSON, omnictl auth fail,
# omnictl-not-found). Per-machine apply failures are logged as ERROR but
# do not abort — one bad machine shouldn't block the rest.

set -euo pipefail

readonly LABELS_JSON="${1:?usage: $0 <labels.json>}"

[[ -s "$LABELS_JSON" ]] || { echo "[sync-machine-labels] empty/missing $LABELS_JSON — nothing to do"; exit 0; }
command -v omnictl >/dev/null || { echo "[sync-machine-labels] omnictl not in PATH" >&2; exit 1; }
command -v jq >/dev/null      || { echo "[sync-machine-labels] jq not in PATH"      >&2; exit 1; }
[[ -n "${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "[sync-machine-labels] OMNI_SERVICE_ACCOUNT_KEY unset" >&2; exit 1; }

# Fetch ALL registered Machines, regardless of cluster binding —
# `--selector omni.sidero.dev/cluster=<name>` only matches machines
# already bound to a MachineSet. The labels we apply here are what
# DRIVES the binding: `node.antinvestor.io/role=…` matches the cp /
# workers MachineClass selectors, MachineProvisionController then
# binds the machine to the cluster. So the right time to label is
# BEFORE binding, when the machine is still unattached.
#
# We tolerate empty/no-output (no machines yet) gracefully — the
# script is idempotent and will pick up newly-registered machines
# on the next apply.
machines_json=$(omnictl get machinestatus --output json 2>/dev/null || true)

# omnictl emits one JSON object per resource (NDJSON, not a single array).
# Slurp into a single array so jq can index by hostname.
machines_arr=$(printf '%s\n' "$machines_json" | jq -cs 'flatten')
machine_count=$(jq -r 'length' <<< "$machines_arr")
echo "[sync-machine-labels] cluster=${OMNI_CLUSTER:-stawi}, registered machines: $machine_count"

# Iterate (node_name, labels-map) pairs from the input JSON.
applied=0
skipped=0
errored=0

while IFS= read -r entry; do
  node_name=$(jq -r '.key' <<< "$entry")
  labels=$(jq -c '.value' <<< "$entry")

  # Resolve hostname → machine-id. Fall back to nodename if hostname is
  # unset (some Talos schematics report only the system uuid).
  machine_id=$(jq -r --arg n "$node_name" '
    .[] | select(
      (.spec.network.hostname // "") == $n
      or (.spec.hostname // "") == $n
    ) | .metadata.id
  ' <<< "$machines_arr" | head -n1)

  if [[ -z "$machine_id" ]]; then
    echo "[sync-machine-labels] WARN $node_name: not yet registered in Omni — skipping"
    skipped=$((skipped + 1))
    continue
  fi

  # Build --user-label flags. Empty-value labels (k=) are valid in Omni.
  user_label_args=()
  while IFS=$'\t' read -r k v; do
    [[ -n "$k" ]] || continue
    user_label_args+=(--user-label "${k}=${v}")
  done < <(jq -r 'to_entries[] | "\(.key)\t\(.value)"' <<< "$labels")

  if [[ ${#user_label_args[@]} -eq 0 ]]; then
    echo "[sync-machine-labels] $node_name (id=$machine_id): no labels to set"
    continue
  fi

  echo "[sync-machine-labels] $node_name (id=$machine_id): ${#user_label_args[@]} label(s)"
  if omnictl machine update "$machine_id" "${user_label_args[@]}" 2>&1 | sed 's/^/  /'; then
    applied=$((applied + 1))
  else
    echo "[sync-machine-labels] ERROR $node_name: omnictl machine update failed"
    errored=$((errored + 1))
  fi
done < <(jq -c 'to_entries[]' "$LABELS_JSON")

echo "[sync-machine-labels] done: applied=$applied skipped=$skipped errored=$errored"
exit 0
