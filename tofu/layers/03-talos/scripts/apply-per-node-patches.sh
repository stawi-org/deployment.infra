#!/usr/bin/env bash
#
# tofu/layers/03-talos/scripts/apply-per-node-patches.sh
#
# Workflow-invoked: pulls per-node Talos patches from R2, resolves
# each node's Omni machine-id, wraps in a ConfigPatches.omni.sidero.dev
# envelope (id = stawi-<node>-link, machine label scoping), and
# applies via omnictl. Idempotent — re-running with no change is a
# no-op apply per Omni's resource semantics.
#
# Sibling to sync-machine-label.sh; reuses the same hostname-then-
# ipv4 matching logic to map node names to Omni machine IDs.
#
# Inputs:
#   $1                            R2 prefix to read patches from
#                                  (e.g. production/per-node-patches/v1.13.0).
#   $NODES_JSON                    Path to JSON file mapping node-name →
#                                    { "ipv4": "1.2.3.4" | null }, written
#                                    by tofu (same shape as sync-machine-
#                                    labels.sh's NODE_LABELS_JSON.ipv4 sub-
#                                    field).
#   $OMNI_CLUSTER                  Cluster name (logging only).
#   $OMNI_ENDPOINT                 omnictl reads from env.
#   $OMNI_SERVICE_ACCOUNT_KEY      omnictl reads from env.
#   $AWS_ACCESS_KEY_ID             R2 read creds.
#   $AWS_SECRET_ACCESS_KEY         R2 read creds.
#   $R2_ACCOUNT_ID                 R2 endpoint construction.
#
# Behaviour:
#   - Per-node: fail-isolated. A failed apply for one node logs
#     ERROR and continues with others.
#   - Empty R2 prefix is a no-op.

set -euo pipefail

readonly R2_PREFIX="${1:?usage: $0 <r2-prefix>}"
readonly NODES_JSON="${NODES_JSON:?NODES_JSON env var required}"

[[ -s "$NODES_JSON" ]] || { echo "[apply-per-node-patches] empty/missing $NODES_JSON — nothing to do"; exit 0; }
command -v omnictl >/dev/null || { echo "[apply-per-node-patches] omnictl not in PATH" >&2; exit 1; }
command -v aws     >/dev/null || { echo "[apply-per-node-patches] aws not in PATH" >&2; exit 1; }
command -v jq      >/dev/null || { echo "[apply-per-node-patches] jq not in PATH" >&2; exit 1; }
[[ -n "${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "[apply-per-node-patches] OMNI_SERVICE_ACCOUNT_KEY unset" >&2; exit 1; }
[[ -n "${R2_ACCOUNT_ID:-}" ]]            || { echo "[apply-per-node-patches] R2_ACCOUNT_ID unset" >&2; exit 1; }

readonly R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Stage R2 patches into a workspace tempdir.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "[apply-per-node-patches] syncing s3://cluster-tofu-state/${R2_PREFIX}/ → $workdir/"
aws s3 sync "s3://cluster-tofu-state/${R2_PREFIX}/" "$workdir/" \
  --endpoint-url "$R2_ENDPOINT" \
  --region us-east-1 \
  --no-progress \
  >/dev/null

# Fetch Omni machine inventory once. Same NDJSON-then-flatten dance
# as sync-machine-label.sh — omnictl can transiently emit non-JSON
# (e.g. partial output during the hourly omni-backup snapshot), so
# guard with a JSON-validity fallback to '[]'.
fetch_machines() {
  local result
  result=$(omnictl get machinestatus --output json 2>/dev/null | jq -cs 'flatten' 2>/dev/null) || result=''
  if [[ -z "$result" ]] || ! jq -e . >/dev/null 2>&1 <<<"$result"; then
    result='[]'
  fi
  printf '%s' "$result"
}

machines_arr=$(fetch_machines)
machine_count=$(jq -r 'length' <<<"$machines_arr")
echo "[apply-per-node-patches] cluster=${OMNI_CLUSTER:-stawi}, registered machines: $machine_count"

# Diagnostic — when a node-name doesn't match by hostname or IP
# we want to be able to see what Omni knows about each machine.
if (( machine_count > 0 )); then
  echo "[apply-per-node-patches] machine inventory:"
  jq -r '.[] | "  id=\(.metadata.id) host=\(.spec.network.hostname // "?") addrs=\(.spec.network.addresses // [] | join(","))"' <<<"$machines_arr"
fi

if (( machine_count == 0 )); then
  echo "[apply-per-node-patches] WARN: no machines registered — nothing to apply"
  exit 0
fi

applied=0
skipped=0
errored=0

while IFS= read -r entry; do
  node_name=$(jq -r '.key' <<<"$entry")
  ipv4=$(jq -r '.value.ipv4 // ""' <<<"$entry")

  patch_file="$workdir/${node_name}.yaml"
  if [[ ! -s "$patch_file" ]]; then
    echo "[apply-per-node-patches] WARN $node_name: no patch in R2 (skipping — onprem or unrendered)"
    skipped=$((skipped + 1))
    continue
  fi

  # Match by hostname first, then by any-address-matches-ipv4.
  # Identical logic to sync-machine-label.sh.
  machine_id=$(jq -r --arg n "$node_name" --arg ip "$ipv4" '
    (.[] | select((.spec.network.hostname // "") == $n) | .metadata.id),
    (.[] | select(
       ($ip != "") and (
         any(.spec.network.addresses // [] | .[];
             (split("/")[0]) == $ip)
       )
     ) | .metadata.id)
  ' <<<"$machines_arr" | head -n1)

  if [[ -z "$machine_id" ]]; then
    echo "[apply-per-node-patches] WARN $node_name (ipv4=$ipv4): no matching Omni machine — skipping"
    skipped=$((skipped + 1))
    continue
  fi

  # Wrap the entire (possibly multi-doc) rendered YAML in a SINGLE
  # ConfigPatch envelope. Omni delegates the multi-doc parsing to
  # Talos's configpatcher.Apply (multi-doc-aware in Talos ≥1.5);
  # each v1alpha1 standalone document (LinkConfig, HostnameConfig,
  # ResolverConfig) survives the merge intact. No per-doc split
  # needed.
  #
  # Selector mechanism: per-machine ConfigPatches are matched ONLY
  # by metadata.labels for the four system keys
  # (omni.sidero.dev/{cluster, machine-set, cluster-machine,
  # machine}). The `spec.target_label_selectors` field is fictional
  # — silently dropped at unmarshal because it isn't in the proto
  # (siderolabs/omni client/api/omni/specs/omni.proto:727-738).
  # Use `omni.sidero.dev/cluster-machine=<machine-uuid>` to bind a
  # patch to one machine. Verified by source review of
  # configpatch.Helper.Get (siderolabs/omni internal/backend/runtime/
  # omni/controllers/omni/internal/configpatch/configpatch.go:40-84)
  # 2026-05-06.
  #
  # CRITICAL design constraints:
  #
  #   1. metadata.labels MUST NOT include omni.sidero.dev/cluster
  #      AS THE ONLY label. Cluster-template sync claims ownership
  #      of any patch carrying that label without a more-specific
  #      machine selector and prunes it. Adding the per-machine
  #      `omni.sidero.dev/cluster-machine=<uuid>` label is fine —
  #      sync's prune is keyed on cluster-only patches.
  #
  #   2. The `omni.sidero.dev/cluster-machine` value is the Omni
  #      Machine UUID (already resolved into $machine_id above by
  #      the hostname/ipv4 matcher), NOT our friendly node name.

  envelope_file=$(mktemp -t "stawi-${node_name}-link.XXXXXX.yaml")
  cat > "$envelope_file" <<MANIFEST
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: stawi-${node_name}-link
  labels:
    stawi.local/per-node-link: "true"
    omni.sidero.dev/cluster: ${OMNI_CLUSTER:-stawi}
    omni.sidero.dev/cluster-machine: ${machine_id}
spec:
  data: |
$(printf '%s\n' "$(<"$patch_file")" | sed 's/^/    /')
MANIFEST
  echo "[apply-per-node-patches] $node_name (machine=$machine_id): applying"
  if omnictl apply -f "$envelope_file" 2>&1 | sed 's/^/  /'; then
    applied=$((applied + 1))
  else
    echo "[apply-per-node-patches] ERROR $node_name: omnictl apply ConfigPatches failed"
    errored=$((errored + 1))
  fi
  rm -f "$envelope_file"

done < <(jq -c 'to_entries[]' "$NODES_JSON")

echo "[apply-per-node-patches] done: applied=$applied skipped=$skipped errored=$errored"
# Per-node fail-isolation: partial failure exits 0 (other nodes
# may have applied successfully). But total failure — every
# attempted apply errored and nothing succeeded — should mark the
# step failed so the GitHub Actions log doesn't show green.
if (( errored > 0 && applied == 0 )); then
  echo "[apply-per-node-patches] ERROR: all attempted applies failed — marking step failed" >&2
  exit 1
fi
# Silent-skip detection: if R2 had per-node patch files but we
# applied zero, the NODES_JSON ↔ R2 patch set diverged (operator-
# managed inventory dropped a node that still has a patch, or the
# caller built NODES_JSON from an empty/wrong source). The 2026-05-21
# rollout hit exactly this — PR #254 retired the tfstate resource the
# caller read from, so NODES_JSON was {} but R2 had 7 patches, and the
# step passed green with applied=0. Fail the step instead.
r2_patch_count=$(find "$workdir" -maxdepth 1 -type f -name '*.yaml' | wc -l)
if (( r2_patch_count > 0 && applied == 0 )); then
  echo "[apply-per-node-patches] ERROR: R2 has $r2_patch_count per-node patch file(s) but applied=0. Likely NODES_JSON is empty or hostname/ipv4 matching failed for every entry. The caller's NODES_JSON source has drifted from R2 inventory. Marking step failed." >&2
  exit 1
fi
exit 0
