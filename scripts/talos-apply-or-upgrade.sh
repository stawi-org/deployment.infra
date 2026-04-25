#!/usr/bin/env bash
# Idempotent per-node Talos config delivery + version reconciliation.
# Mirrors the three-state flow from antinvestor/deployments'
# talos_node_setup role:
#
#   maintenance   → talosctl apply-config --insecure (clean install path)
#   running, version match    → no-op (idempotent)
#   running, version mismatch → talosctl upgrade --image <factory>:<ver>
#                               (in-place upgrade, etcd survives)
#
# Inputs (env, set by the null_resource provisioner):
#   NODE_IP        — public IP to dial
#   NODE_NAME      — for log lines
#   TARGET_VERSION — desired Talos version (e.g. v1.12.6)
#   INSTALLER_URL  — factory installer URL prefix
#                    (e.g. factory.talos.dev/installer/<schematic>)
#   MACHINE_CONFIG — full rendered machine config for this node
#   TALOSCONFIG    — talosconfig YAML for mTLS calls (post-bootstrap)
#
# Exit codes:
#   0 — node is at TARGET_VERSION with config applied
#   1 — irrecoverable error; surfaces via tofu provisioner failure
set -uo pipefail

: "${NODE_IP:?NODE_IP must be set}"
: "${NODE_NAME:?NODE_NAME must be set}"
: "${TARGET_VERSION:?TARGET_VERSION must be set}"
: "${INSTALLER_URL:?INSTALLER_URL must be set}"
: "${MACHINE_CONFIG:?MACHINE_CONFIG must be set}"
: "${TALOSCONFIG:?TALOSCONFIG must be set}"

scratch=$(mktemp -d); chmod 700 "$scratch"
trap 'rm -rf "$scratch"' EXIT
cfg_file="$scratch/machine.yaml"; printf '%s' "$MACHINE_CONFIG" > "$cfg_file"
tc_file="$scratch/talosconfig";   printf '%s' "$TALOSCONFIG"    > "$tc_file"

log() { printf '[%s] %s\n' "$NODE_NAME" "$*"; }

# Detect node stage. --insecure works for maintenance-mode nodes; mTLS
# is needed once the cluster CA is loaded. Try insecure first since
# machinestatus is readable in both modes.
detect_stage() {
  local out rc
  out=$(timeout 10 talosctl get machinestatus --insecure \
    --nodes "$NODE_IP" -o jsonpath='{.spec.stage}' 2>&1)
  rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  # mTLS path — node has rejected insecure (configured cluster).
  out=$(timeout 10 talosctl --talosconfig "$tc_file" \
    --endpoints "$NODE_IP" --nodes "$NODE_IP" \
    get machinestatus -o jsonpath='{.spec.stage}' 2>&1)
  rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    printf '%s' "$out"
    return 0
  fi
  printf 'unreachable'
  return 1
}

stage=$(detect_stage) || true
log "detected stage=$stage"

case "$stage" in
  maintenance)
    log "applying config via --insecure (clean install)"
    talosctl apply-config --insecure \
      --nodes "$NODE_IP" --file "$cfg_file"
    log "applied; node will exit maintenance shortly"
    ;;

  running|booting)
    server_version=$(talosctl --talosconfig "$tc_file" \
      --endpoints "$NODE_IP" --nodes "$NODE_IP" version 2>/dev/null \
      | awk '$1=="Server:"{f=1;next} f && $1=="Tag:"{print $2; exit}')
    if [[ -z "$server_version" ]]; then
      log "::error::could not read server version"
      exit 1
    fi
    log "current=$server_version target=$TARGET_VERSION"
    if [[ "$server_version" == "$TARGET_VERSION" ]]; then
      log "version matches — idempotent no-op"
      exit 0
    fi
    log "upgrading to $TARGET_VERSION"
    talosctl --talosconfig "$tc_file" \
      --endpoints "$NODE_IP" --nodes "$NODE_IP" upgrade \
      --image "${INSTALLER_URL}:${TARGET_VERSION}" \
      --wait --timeout 5m
    log "upgrade complete"
    ;;

  *)
    log "::error::node in stage '$stage' (expected maintenance|running|booting)"
    exit 1
    ;;
esac
