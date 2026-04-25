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
#   NODE_IP             — public IP to dial
#   NODE_NAME           — for log lines
#   NODE_ROLE           — controlplane | worker. Controls failure handling:
#                         worker failures log a warning and exit 0 so they
#                         don't abort sibling node applies; controlplane
#                         failures fail the tofu apply (quorum matters).
#   TARGET_VERSION      — desired Talos version (e.g. v1.12.6)
#   INSTALLER_URL       — factory installer URL prefix
#                         (e.g. factory.talos.dev/installer/<schematic>)
#   MACHINE_CONFIG_FILE — path to the rendered machine config for this node
#   TALOSCONFIG_FILE    — path to talosconfig YAML for mTLS calls
#
# Configs are staged on disk by tofu's local_sensitive_file resources
# rather than passed inline, because Talos machine configs (~30-50 KB)
# combined with a talosconfig (~2 KB) plus tofu-injected env easily
# exceed Linux's ARG_MAX (~128 KB on the runner).
#
# Exit codes:
#   0 — node is at TARGET_VERSION with config applied, OR a worker that
#       failed (logged as warning, doesn't break sibling applies)
#   1 — irrecoverable controlplane error; surfaces via tofu provisioner failure
set -uo pipefail

: "${NODE_IP:?NODE_IP must be set}"
: "${NODE_NAME:?NODE_NAME must be set}"
: "${NODE_ROLE:?NODE_ROLE must be set (controlplane|worker)}"
: "${TARGET_VERSION:?TARGET_VERSION must be set}"
: "${INSTALLER_URL:?INSTALLER_URL must be set}"
: "${MACHINE_CONFIG_FILE:?MACHINE_CONFIG_FILE must be set}"
: "${TALOSCONFIG_FILE:?TALOSCONFIG_FILE must be set}"

[[ -r "$MACHINE_CONFIG_FILE" ]] || { echo "::error::cannot read $MACHINE_CONFIG_FILE" >&2; exit 1; }
[[ -r "$TALOSCONFIG_FILE"    ]] || { echo "::error::cannot read $TALOSCONFIG_FILE"    >&2; exit 1; }

cfg_file="$MACHINE_CONFIG_FILE"
tc_file="$TALOSCONFIG_FILE"

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

# Wrap the apply path in a function so we can capture its exit code and
# decide policy: controlplane failures fail the apply, worker failures
# warn-and-continue. Use 'return' inside; never 'exit'.
do_apply() {
  # Retry on unreachable for up to 5 min — covers post-reinstall boot,
  # transient network blips, apid still binding to :50000. Steady-state
  # nodes respond instantly; we only loop when the node is genuinely
  # in transition.
  local stage=""
  for attempt in $(seq 1 30); do
    stage=$(detect_stage) || true
    if [[ "$stage" != "unreachable" && -n "$stage" ]]; then
      break
    fi
    log "attempt $attempt/30: stage=unreachable, retrying in 10s"
    sleep 10
  done
  log "detected stage=$stage"

  case "$stage" in
    unreachable)
      # Persistently unreachable on :50000 after 5 min of retries. No
      # apply path exists for a node we can't talk to, so we exit
      # non-fatally regardless of role — failing tofu here would just
      # punish the rest of the cluster for one stuck VPS. Recovery
      # goes through the node-recovery workflow (wipe + reinstall).
      # Sentinel rc=2 lets the dispatcher distinguish this from a
      # real apply error.
      log "::warning::unreachable on :50000 after 5 min — skipping apply (use node-recovery to fix)"
      return 2
      ;;

    maintenance)
      log "applying config via --insecure (clean install)"
      talosctl apply-config --insecure \
        --nodes "$NODE_IP" --file "$cfg_file" || return 1
      log "applied; node will exit maintenance shortly"
      ;;

    running|booting)
      local server_version
      server_version=$(talosctl --talosconfig "$tc_file" \
        --endpoints "$NODE_IP" --nodes "$NODE_IP" version 2>/dev/null \
        | awk '$1=="Server:"{f=1;next} f && $1=="Tag:"{print $2; exit}')
      if [[ -z "$server_version" ]]; then
        log "::error::could not read server version"
        return 1
      fi
      log "current=$server_version target=$TARGET_VERSION"
      if [[ "$server_version" == "$TARGET_VERSION" ]]; then
        log "version matches — idempotent no-op"
        return 0
      fi
      log "upgrading to $TARGET_VERSION"
      talosctl --talosconfig "$tc_file" \
        --endpoints "$NODE_IP" --nodes "$NODE_IP" upgrade \
        --image "${INSTALLER_URL}:${TARGET_VERSION}" \
        --wait --timeout 5m || return 1
      log "upgrade complete"
      ;;

    *)
      log "::error::node in stage '$stage' (expected maintenance|running|booting)"
      return 1
      ;;
  esac
  return 0
}

# Per-node failure isolation:
#   rc=0 — applied or no-op, all good.
#   rc=2 — node unreachable; non-fatal regardless of role. The cluster
#          can still progress; downstream wait_apiserver only needs
#          ≥1 healthy CP. Operator runs node-recovery to rejoin.
#   rc=1 — real apply error against a reachable node. Fail tofu for
#          CPs (etcd quorum / apiserver depend on them); warn-and-
#          continue for workers (a single misbehaving worker shouldn't
#          block sibling CP applies in the same run).
if do_apply; then
  rc=0
else
  rc=$?
fi

if (( rc == 2 )); then
  exit 0
fi

if (( rc != 0 )) && [[ "$NODE_ROLE" == "worker" ]]; then
  log "::warning::worker apply failed (rc=$rc) — continuing per worker-failure isolation policy"
  exit 0
fi
exit $rc
