#!/usr/bin/env bash
#
# tofu/layers/03-talos/scripts/sync-machine-labels.sh
#
# Idempotent reconciler that copies tofu's per-node labels onto each
# registered Omni Machine. Called from cluster.tf's
# null_resource.omnictl_machine_labels.
#
# How labels are applied:
#   We `omnictl apply -f -` a MachineLabels.omni.sidero.dev resource
#   per machine, with the labels living in metadata.labels (COSI-style;
#   MachineLabelsSpec is empty). A controller in Omni then reconciles
#   those labels onto the matching MachineStatus, which is what the
#   MachineClass selectors (`role=cp`, `role=worker`) match against.
#
#   `omnictl machine update --user-label k=v` from the README is wrong
#   — that subcommand doesn't exist (only `omnictl configure machine`
#   does, and that's for siderolink mode / token reset).
#
# How nodes are matched to machines:
#   1. Hostname:  spec.network.hostname == <node_name>  (works for OCI
#                 — Talos picks up the OCI hostname-label).
#   2. Public IP: any addr in spec.network.addresses == <ipv4>  (works
#                 for Contabo, where Talos doesn't get the friendly
#                 hostname from the platform and uses the system UUID
#                 instead).
#
# Inputs:
#   $1                       Path to JSON file mapping
#                              <node_name> → {
#                                "labels": { "k": "v", ... },
#                                "ipv4":   "1.2.3.4" | null
#                              }
#   $OMNI_CLUSTER            Cluster name (used in log lines).
#   $OMNI_ENDPOINT           Set in caller env; omnictl reads it.
#   $OMNI_SERVICE_ACCOUNT_KEY Set in caller env; omnictl reads it.
#
# Behaviour:
#   - Idempotent: re-running with the same input is a no-op apply.
#   - Per-node failures log ERROR but don't abort.
#   - Empty input is a no-op.

set -euo pipefail

readonly LABELS_JSON="${1:?usage: $0 <labels.json>}"

[[ -s "$LABELS_JSON" ]] || { echo "[sync-machine-labels] empty/missing $LABELS_JSON — nothing to do"; exit 0; }
command -v omnictl >/dev/null || { echo "[sync-machine-labels] omnictl not in PATH" >&2; exit 1; }
command -v jq >/dev/null      || { echo "[sync-machine-labels] jq not in PATH"      >&2; exit 1; }
[[ -n "${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "[sync-machine-labels] OMNI_SERVICE_ACCOUNT_KEY unset" >&2; exit 1; }

# Fetch ALL registered MachineStatuses, regardless of cluster binding.
# Newly-registered (still-unbound) machines are exactly the ones we
# need to label so MachineClass selectors can match and bind them.
machines_arr=$(omnictl get machinestatus --output json 2>/dev/null | jq -cs 'flatten' || echo '[]')
machine_count=$(jq -r 'length' <<< "$machines_arr")
echo "[sync-machine-labels] cluster=${OMNI_CLUSTER:-stawi}, registered machines: $machine_count"

# Diagnostic — surface what Omni knows about each machine so when a
# node-name doesn't match by hostname or IP we can at least see where
# the gap is.
if (( machine_count > 0 )); then
  echo "[sync-machine-labels] machine inventory:"
  jq -r '.[] | "  id=\(.metadata.id) host=\(.spec.network.hostname // "?") addrs=\(.spec.network.addresses // [] | join(","))"' <<< "$machines_arr"
fi

applied=0
skipped=0
errored=0

while IFS= read -r entry; do
  node_name=$(jq -r '.key' <<< "$entry")
  labels=$(jq -c '.value.labels // {}' <<< "$entry")
  ipv4=$(jq -r '.value.ipv4 // ""' <<< "$entry")

  # Match by hostname first; fall back to IP.
  machine_id=$(jq -r --arg n "$node_name" --arg ip "$ipv4" '
    # 1. exact hostname match
    (.[] | select((.spec.network.hostname // "") == $n) | .metadata.id),
    # 2. ipv4 match in addresses
    (.[] | select(($ip != "") and (any(.spec.network.addresses // [] | .[]; . == $ip))) | .metadata.id)
  ' <<< "$machines_arr" | head -n1)

  if [[ -z "$machine_id" ]]; then
    echo "[sync-machine-labels] WARN $node_name (ipv4=$ipv4): no matching Omni machine — skipping"
    skipped=$((skipped + 1))
    continue
  fi

  label_count=$(jq -r 'length' <<< "$labels")
  if (( label_count == 0 )); then
    echo "[sync-machine-labels] $node_name (id=$machine_id): no labels to set"
    continue
  fi

  echo "[sync-machine-labels] $node_name (id=$machine_id): $label_count label(s)"

  # Build a MachineLabels resource manifest as JSON (omnictl apply
  # accepts JSON or YAML — JSON is easier to construct safely from
  # arbitrary label keys/values). Labels live in metadata.labels
  # (COSI-style); MachineLabelsSpec is empty.
  manifest=$(jq -n --arg id "$machine_id" --argjson labels "$labels" '{
    metadata: {
      namespace: "default",
      type:      "MachineLabels.omni.sidero.dev",
      id:        $id,
      labels:    $labels,
    },
    spec: {},
  }')

  if printf '%s\n' "$manifest" | omnictl apply -f - 2>&1 | sed 's/^/  /'; then
    applied=$((applied + 1))
  else
    echo "[sync-machine-labels] ERROR $node_name: omnictl apply MachineLabels failed"
    errored=$((errored + 1))
  fi
done < <(jq -c 'to_entries[]' "$LABELS_JSON")

echo "[sync-machine-labels] done: applied=$applied skipped=$skipped errored=$errored"
exit 0
