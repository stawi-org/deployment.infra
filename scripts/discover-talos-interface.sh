#!/usr/bin/env bash
# scripts/discover-talos-interface.sh
#
# Tofu `external` data source program. Takes JSON {"node":"<ip>"} on
# stdin, discovers the primary ethernet interface name on that Talos
# node via talosctl, outputs {"interface":"<name>"} on stdout.
#
# Mirrors Ansible's 02-discover-interface.yml:
#   1. If talosconfig is set in the environment (TALOSCONFIG), try
#      authenticated access first (works once the node is configured).
#   2. Fall back to insecure maintenance-mode access (works pre-config).
#   3. Retry insecure for up to 5 minutes — nodes often take that long
#      to boot into maintenance mode after a Contabo reinstall.
#
# Requires: talosctl in PATH, jq.
# Tofu consumes the "interface" field from stdout JSON.

set -euo pipefail

INPUT=$(cat)
NODE=$(printf '%s' "$INPUT" | jq -r .node)
[[ -n "$NODE" && "$NODE" != "null" ]] || { echo >&2 "missing .node in input"; exit 1; }

# Match first physical ethernet link, same filter as the Ansible role.
FILTER='select(.spec.type=="ether" and .spec.kind=="") | .metadata.id'

try_auth() {
  [[ -n "${TALOSCONFIG:-}" ]] || return 1
  timeout 15 talosctl get link \
    --talosconfig "$TALOSCONFIG" \
    --endpoints "$NODE" --nodes "$NODE" -o json 2>/dev/null \
    | jq -r "$FILTER" | head -1
}

try_insecure() {
  timeout 15 talosctl get link --insecure --nodes "$NODE" -o json 2>/dev/null \
    | jq -r "$FILTER" | head -1
}

IF="$(try_auth || true)"
if [[ -z "$IF" ]]; then
  # Up to 5 min of retries while the node provisions.
  for _ in $(seq 1 30); do
    IF="$(try_insecure || true)"
    [[ -n "$IF" ]] && break
    sleep 10
  done
fi

[[ -n "$IF" ]] || { echo >&2 "could not determine primary interface for $NODE"; exit 1; }
printf '{"interface":"%s"}\n' "$IF"
