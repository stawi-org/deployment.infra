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

# Pin NODE_IP into /etc/hosts to the CURRENT NODE_IPV4 from tofu
# state (passed by the provisioner). Always overwrites any stale
# pin — the workflow's pre-resolve step ran ONCE at startup, before
# layer 02 might have destroy+create'd an OCI instance and rotated
# its ephemeral public IP. The pre-resolved /etc/hosts entry would
# then point at the old IP; talosctl would dial it and time out
# for the entire 5-min retry budget. By using tofu's authoritative
# current-state IP and forcibly overwriting any stale entries,
# every apply uses the live IP regardless of pre-resolve timing
# or DNS propagation lag.
#
# We also pin a synthetic AAAA = ::ffff:<ipv4> so any AAAA query
# returns an IPv4-mapped address (kernel routes via IPv4). This
# avoids systemd-resolved returning the cluster's real public IPv6
# from Cloudflare, which the IPv4-only GitHub Actions runner can't
# reach. Combined with GODEBUG=netdns=cgo (set by the provisioner),
# talosctl's resolver actually consults /etc/hosts — pure-Go gRPC
# resolver bypasses it.
pin_node_ip_to_etc_hosts() {
  case "$NODE_IP" in
    *[!0-9.]*) ;;     # contains non-digit-or-dot → looks like hostname
    *) return 0 ;;    # pure IPv4, nothing to pin
  esac
  if [[ -z "${NODE_IPV4:-}" ]]; then
    log "NODE_IPV4 unset; can't pin $NODE_IP — talosctl will fall through to systemd-resolved"
    return 0
  fi
  # Drop any stale pin (could be the pre-resolve from before an
  # OCI instance recreate). sed -i edits in place; the pattern
  # matches lines whose hostname column equals NODE_IP exactly.
  if grep -q "[[:space:]]${NODE_IP}\$" /etc/hosts 2>/dev/null; then
    sudo sed -i "/[[:space:]]${NODE_IP}\$/d" /etc/hosts
  fi
  log "pinning $NODE_IP -> $NODE_IPV4 in /etc/hosts (also synthetic AAAA ::ffff:$NODE_IPV4)"
  echo "$NODE_IPV4 $NODE_IP"        | sudo tee -a /etc/hosts >/dev/null
  echo "::ffff:$NODE_IPV4 $NODE_IP" | sudo tee -a /etc/hosts >/dev/null
}
pin_node_ip_to_etc_hosts

# Detect node stage. --insecure works for maintenance-mode nodes; mTLS
# is needed once the cluster CA is loaded. Try insecure first since
# machinestatus is readable in both modes. 30s per probe — the previous
# 10s was eaten by slow cross-cloud TLS handshakes (OCI from a US-east
# runner, etc.) and produced false-positive unreachables.
#
# Diagnostic from each failed probe is written to script stderr (>&2)
# rather than a captured local var — detect_stage runs inside a $()
# subshell, so any variable assignment is invisible to the caller.
detect_stage() {
  local out rc
  out=$(timeout 30 talosctl get machinestatus --insecure \
    --nodes "$NODE_IP" -o jsonpath='{.spec.stage}' 2>/tmp/probe-stderr.$$)
  rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    rm -f /tmp/probe-stderr.$$
    printf '%s' "$out"
    return 0
  fi
  echo "[$NODE_NAME] insecure probe rc=$rc, stderr: $(cat /tmp/probe-stderr.$$ 2>/dev/null | head -3 | tr '\n' ' / ')" >&2
  # mTLS path — node has rejected insecure (configured cluster).
  out=$(timeout 30 talosctl --talosconfig "$tc_file" \
    --endpoints "$NODE_IP" --nodes "$NODE_IP" \
    get machinestatus -o jsonpath='{.spec.stage}' 2>/tmp/probe-stderr.$$)
  rc=$?
  if (( rc == 0 )) && [[ -n "$out" ]]; then
    rm -f /tmp/probe-stderr.$$
    printf '%s' "$out"
    return 0
  fi
  echo "[$NODE_NAME] mtls probe rc=$rc, stderr: $(cat /tmp/probe-stderr.$$ 2>/dev/null | head -3 | tr '\n' ' / ')" >&2
  rm -f /tmp/probe-stderr.$$
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

      # Push the rendered config via mTLS regardless of version match.
      # Talos's apply-config is idempotent when the on-node config
      # already matches; applies the diff hot when it doesn't (e.g. we
      # added a new patch but the node version is unchanged, like the
      # Contabo IPv6 patch + Flannel public-ip-overwrite annotation).
      # Without this, version-match nodes silently keep stale configs
      # forever — Flannel-on-worker hit "Unable to find default v6
      # route" on contabo-bwire-node-3 because the node was still
      # running the pre-IPv6-patch config.
      log "applying config (idempotent if no diff)"
      talosctl --talosconfig "$tc_file" \
        --endpoints "$NODE_IP" --nodes "$NODE_IP" \
        apply-config --file "$cfg_file" || return 1

      if [[ "$server_version" == "$TARGET_VERSION" ]]; then
        log "version matches — config applied, done"
        return 0
      fi
      log "upgrading to $TARGET_VERSION"
      # Talos's upgrade RPC takes a cluster-wide etcd mutex AND
      # requires every etcd member to be healthy before it'll start
      # another node's upgrade. With for_each on apply_node_config
      # firing all 4 CP upgrades in parallel, exactly one acquires
      # the mutex; the rest fail immediately with:
      #   "failed to acquire upgrade mutex: Locked by another session"
      #   "etcd member <id> is not healthy; all members must be
      #    healthy to perform an upgrade"
      # Retry these specific errors so upgrades naturally serialize
      # — one CP completes its reboot+rejoin, mutex frees, etcd
      # becomes healthy again, the next call gets in. 20 * 30s = 10
      # min retry budget per node, more than enough for a couple of
      # peers to upgrade ahead of us.
      # Helper: query the live server version. Empty string if unreachable.
      probe_server_version() {
        talosctl --talosconfig "$tc_file" \
          --endpoints "$NODE_IP" --nodes "$NODE_IP" version 2>/dev/null \
          | awk '$1=="Server:"{f=1;next} f && $1=="Tag:"{print $2; exit}'
      }

      local up_out up_rc
      for up_attempt in $(seq 1 20); do
        up_out=$(talosctl --talosconfig "$tc_file" \
          --endpoints "$NODE_IP" --nodes "$NODE_IP" upgrade \
          --image "${INSTALLER_URL}:${TARGET_VERSION}" \
          --wait --timeout 5m 2>&1)
        up_rc=$?
        if (( up_rc == 0 )); then
          log "upgrade complete"
          return 0
        fi

        # talosctl client newer than the server can hit two non-fatal
        # rc=1 paths that still leave the upgrade succeeding on-node:
        #   1. "New upgrade API is not available, falling back to legacy"
        #      — legacy upgrade RPC doesn't return actor IDs, talosctl's
        #      --wait times out with rc=1 even on success.
        #   2. The on-node reboot mid-upgrade drops the talosctl
        #      connection ("connection refused" / "context deadline
        #      exceeded") before the --wait poll completes.
        # Both manifest as "upgrade failed" but the disk is already
        # being re-imaged. Probe the server version after each rc=1 —
        # if it matches the target, the upgrade actually succeeded
        # and we should return 0. Give the node up to 5 min to come
        # back from the reboot before declaring the version probe
        # final, since legacy upgrades reboot mid-call.
        log "upgrade attempt $up_attempt/20: rc=$up_rc — probing server version (post-reboot may be in flight)"
        local probed=""
        for probe_attempt in $(seq 1 30); do
          probed=$(probe_server_version)
          if [[ "$probed" == "$TARGET_VERSION" ]]; then
            log "post-rc=$up_rc probe: server is at $TARGET_VERSION — treating as success"
            return 0
          fi
          if [[ -n "$probed" ]]; then
            log "  probe $probe_attempt/30: server is at $probed (target $TARGET_VERSION) — waiting"
          else
            log "  probe $probe_attempt/30: server unreachable (post-reboot still booting?) — waiting"
          fi
          sleep 10
        done

        if [[ "$up_out" == *"upgrade mutex"* \
           || "$up_out" == *"is not healthy"* \
           || "$up_out" == *"context deadline exceeded"* \
           || "$up_out" == *"connection refused"* \
           || "$up_out" == *"falling back to legacy"* ]]; then
          log "upgrade attempt $up_attempt/20: still on $probed (target $TARGET_VERSION); cluster busy or fallback in progress, sleeping 30s for next retry"
          sleep 30
          continue
        fi
        log "::error::upgrade failed (rc=$up_rc), server still at $probed: $(echo "$up_out" | head -3)"
        return 1
      done
      log "::error::upgrade exhausted 20 retries; cluster did not free the mutex / become healthy in 10 min"
      return 1
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
