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

# Wait window for newly-reinstalled nodes to phone home and register
# their MachineStatus before we attempt to label them. Set high enough
# to cover the worst case (Contabo VPS reinstall: ~5–15 min disk wipe +
# boot, then SideroLink registration). Override via env if needed.
readonly REGISTRATION_TIMEOUT_SECS="${REGISTRATION_TIMEOUT_SECS:-900}"
readonly REGISTRATION_POLL_SECS="${REGISTRATION_POLL_SECS:-15}"

# Build the list of expected nodes from the input JSON. Each node is
# expected to register a MachineStatus matchable by hostname or any of
# its known IPv4s (CIDR-stripped). Until every expected node matches —
# or REGISTRATION_TIMEOUT_SECS elapses — we keep polling. Without this
# wait, a freshly-reinstalled OCI instance (destroy+create takes a
# few minutes) typically isn't registered by the time tofu reaches
# layer 03, gets silently skipped, never gets labelled, and never
# binds into the cp / workers MachineSet.
expected_count=$(jq -r 'length' "$LABELS_JSON")
echo "[sync-machine-labels] expecting $expected_count node(s) to be registered in Omni"

# `omnictl get machinestatus --output json` emits one JSON object per
# line (NDJSON). `jq -cs 'flatten'` collapses to a single array.
#
# Hardening: validate the result is real JSON before returning. Omni
# can transiently return non-JSON to stdout (e.g. an auth error
# message, or partial output if omni-stack is briefly down for the
# hourly omni-backup snapshot). Without this guard, `--argjson` in
# count_matches would crash on garbage input and `set -e` would
# terminate the polling loop instead of riding out the transient.
fetch_machines() {
  local result
  result=$(omnictl get machinestatus --output json 2>/dev/null | jq -cs 'flatten' 2>/dev/null) || result=''
  if [[ -z "$result" ]] || ! jq -e . >/dev/null 2>&1 <<<"$result"; then
    result='[]'
  fi
  printf '%s' "$result"
}

# Count how many expected nodes are currently matchable. Same matching
# rules used by the apply loop below: hostname == node_name OR any
# CIDR-stripped address == ipv4. Keeps the wait gate consistent with
# the actual labelling logic — a node "matches" iff we'd be able to
# label it.
count_matches() {
  local machines_json="$1"
  jq -n \
    --argjson machines "$machines_json" \
    --slurpfile labels "$LABELS_JSON" '
    [
      $labels[0] | to_entries[] |
      .key as $n | (.value.ipv4 // "") as $ip |
      select(
        any($machines[]?;
          (.spec.network.hostname // "") == $n
          or (
            $ip != "" and
            any(.spec.network.addresses // [] | .[]; (split("/")[0]) == $ip)
          )
        )
      )
    ] | length' 2>/dev/null || echo 0
}

deadline=$(( $(date +%s) + REGISTRATION_TIMEOUT_SECS ))
machines_arr='[]'
matched=0
while :; do
  machines_arr=$(fetch_machines)
  matched=$(count_matches "$machines_arr")
  registered=$(jq -r 'length' <<<"$machines_arr" 2>/dev/null || echo 0)
  echo "[sync-machine-labels] registered=$registered matched=$matched/$expected_count"
  if (( matched >= expected_count )); then
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "[sync-machine-labels] WARN: registration wait timed out after ${REGISTRATION_TIMEOUT_SECS}s — proceeding with $matched/$expected_count matched"
    break
  fi
  sleep "$REGISTRATION_POLL_SECS"
done

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

  # Match by hostname first; fall back to IP. Omni's
  # spec.network.addresses are CIDR-formatted (e.g. `164.68.121.237/24`),
  # so split on `/` before comparing to the bare ipv4 we have from
  # tofu state.
  machine_id=$(jq -r --arg n "$node_name" --arg ip "$ipv4" '
    # 1. exact hostname match
    (.[] | select((.spec.network.hostname // "") == $n) | .metadata.id),
    # 2. ipv4 match against any address (CIDR-stripped)
    (.[] | select(
       ($ip != "") and (
         any(.spec.network.addresses // [] | .[];
             (split("/")[0]) == $ip)
       )
     ) | .metadata.id)
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

  # Build a MachineLabels resource manifest. Labels live in
  # metadata.labels (COSI-style); MachineLabelsSpec is empty. omnictl
  # apply accepts JSON or YAML but doesn't support stdin (`-f -` tries
  # to stat `-` as a filename and fails); use a per-machine temp file.
  manifest=$(jq -n --arg id "$machine_id" --argjson labels "$labels" '{
    metadata: {
      namespace: "default",
      type:      "MachineLabels.omni.sidero.dev",
      id:        $id,
      labels:    $labels,
    },
    spec: {},
  }')
  manifest_file=$(mktemp -t "machinelabels-${machine_id}.XXXXXX.json")
  printf '%s\n' "$manifest" > "$manifest_file"

  if omnictl apply -f "$manifest_file" 2>&1 | sed 's/^/  /'; then
    applied=$((applied + 1))
  else
    echo "[sync-machine-labels] ERROR $node_name: omnictl apply MachineLabels failed"
    errored=$((errored + 1))
  fi
  rm -f "$manifest_file"
done < <(jq -c 'to_entries[]' "$LABELS_JSON")

echo "[sync-machine-labels] done: applied=$applied skipped=$skipped errored=$errored"
exit 0
