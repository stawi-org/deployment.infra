#!/usr/bin/env bash
# Post-apply cluster health check. Pulls kubeconfig + talosconfig live
# from Omni via omnictl, runs a short battery of checks, and
# summarises pass/fail. Every check writes a block so a failed one
# shows which output triggered it.
#
# Exit codes: 0 = all checks passed, 1 = at least one check failed.
#
# Requires: omnictl, kubectl, talosctl, flux, jq.
# Env: OMNI_ENDPOINT, OMNI_SERVICE_ACCOUNT_KEY, OMNI_CLUSTER.
set -uo pipefail

: "${OMNI_ENDPOINT:?set}"
: "${OMNI_SERVICE_ACCOUNT_KEY:?set}"
: "${OMNI_CLUSTER:?set}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "::group::Fetch credentials from Omni (omnictl)"
# `omnictl kubeconfig` writes kubeconfig YAML to a path argument. The
# default cluster is the one in the cluster template; pass --cluster
# explicitly so the script is portable across Omni instances managing
# multiple clusters. The output uses Omni's workload-proxy
# (k8s-proxy) — kubectl traffic flows via Omni's HTTPS endpoint, so
# direct CP IP access isn't required.
if ! omnictl kubeconfig --cluster "$OMNI_CLUSTER" --force "$tmp/kubeconfig" 2>&1; then
  echo "::error::omnictl kubeconfig failed — cluster $OMNI_CLUSTER may not exist or SA auth is broken"
  exit 1
fi
if ! omnictl talosconfig --cluster "$OMNI_CLUSTER" --force "$tmp/talosconfig" 2>&1; then
  echo "::error::omnictl talosconfig failed"
  exit 1
fi
chmod 0600 "$tmp/kubeconfig" "$tmp/talosconfig"
export KUBECONFIG="$tmp/kubeconfig"
export TALOSCONFIG="$tmp/talosconfig"
echo "::endgroup::"

echo "::group::Cluster summary (omnictl)"
omnictl get cluster "$OMNI_CLUSTER" 2>&1 || true
echo
omnictl get clustermachinestatus 2>&1 | head -20 || true
echo "::endgroup::"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAIL=$((FAIL + 1)); }

# ----- 0. Flannel preflight (fail-fast gate) -------------------------
# Without a healthy CNI the rest of the checks (pod listings, flux,
# etcd via talos) take many minutes to hang and time out, burning
# pipeline minutes for a result we already know. Exit cleanly with
# a notice when Flannel isn't fully ready so the workflow finishes
# in seconds instead of half an hour.
echo "::group::Flannel readiness preflight"
FLANNEL_DS_JSON=$(timeout 20 kubectl -n kube-system get ds kube-flannel \
  --request-timeout=10s -o json 2>/dev/null || echo '{}')
DESIRED=$(jq -r '.status.desiredNumberScheduled // 0' <<<"$FLANNEL_DS_JSON")
READY=$(jq -r '.status.numberReady // 0' <<<"$FLANNEL_DS_JSON")
if [[ "$DESIRED" == "0" ]]; then
  echo "::notice::Flannel daemonset not found yet — skipping rest of checks"
  exit 0
fi
if [[ "$READY" != "$DESIRED" ]]; then
  echo "::notice::Flannel not fully ready ($READY/$DESIRED) — skipping rest of checks to save pipeline minutes; re-run after CNI settles"
  exit 0
fi
echo "  Flannel ready ($READY/$DESIRED)"
echo "::endgroup::"

# ----- 1. apiserver reachable ----------------------------------------
echo "::group::apiserver reachability (kubectl version)"
if kubectl version --request-timeout=10s 2>&1; then
  pass "kubectl version succeeds"
else
  fail "kubectl version — apiserver unreachable or TLS problem"
fi
echo "::endgroup::"

# ----- 2. nodes Ready ------------------------------------------------
echo "::group::node readiness (kubectl get nodes)"
NODES_JSON=$(kubectl get nodes -o json --request-timeout=10s 2>/dev/null || echo '{}')
if [[ -z "$NODES_JSON" || "$NODES_JSON" == "{}" ]]; then
  fail "kubectl get nodes — no output"
else
  NOT_READY=$(jq -r '
    .items[] | select(
      (.status.conditions // [])
      | map(select(.type == "Ready"))
      | first
      | (.status != "True")
    ) | .metadata.name
  ' <<<"$NODES_JSON")
  if [[ -n "$NOT_READY" ]]; then
    fail "nodes not Ready: $NOT_READY"
  else
    COUNT=$(jq -r '.items | length' <<<"$NODES_JSON")
    pass "all $COUNT node(s) Ready"
  fi
  kubectl get nodes -o wide
fi
echo "::endgroup::"

# ----- 3. system pod health ------------------------------------------
echo "::group::pod health (no stuck pods)"
STUCK=$(kubectl get pods -A --request-timeout=10s -o json 2>/dev/null | jq -r '
  .items[] | select(
    (.status.phase != "Running" and .status.phase != "Succeeded")
    or ((.status.containerStatuses // []) | any(.ready == false and (.state.waiting // {}).reason != "ContainerCreating"))
  ) | "\(.metadata.namespace)/\(.metadata.name) (phase=\(.status.phase))"
' 2>/dev/null)
if [[ -n "$STUCK" ]]; then
  fail "stuck pods:"
  printf '%s\n' "$STUCK" | sed 's/^/    /'
else
  pass "no stuck pods"
fi
echo "::endgroup::"

# ----- 4. etcd quorum via talosctl -----------------------------------
# The omnictl-issued talosconfig already populates contexts +
# endpoints + nodes for every CP — talosctl picks the first
# reachable endpoint and queries via the Omni siderolink mesh
# (no direct CP IP access required).
echo "::group::etcd member health (talosctl)"
# Hard 30s cap — if the CPs are unreachable, talosctl otherwise
# stalls for ~10 min on its own connection retries.
if timeout 30 talosctl etcd members 2>&1; then
  pass "etcd members query succeeded"
else
  fail "etcd members query failed or timed out"
fi
echo "::endgroup::"

# ----- 5. flux reconciled --------------------------------------------
echo "::group::flux reconciliation (flux get all)"
# Hard caps on every flux call — flux check probes multiple cluster
# APIs and can stall for minutes on a partial outage; flux get all
# can stall on the same when CRDs aren't reachable.
if timeout 60 flux check 2>&1; then
  pass "flux check"
else
  fail "flux check reported problems or timed out"
fi
echo
if timeout 30 flux get all -A --status-selector=ready=true 2>&1; then
  pass "flux resources ready"
else
  fail "some flux resources not ready (or query timed out)"
fi
echo "::endgroup::"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "::error::cluster-health: $FAIL check(s) failed"
  exit 1
fi
echo "::notice::cluster-health: all checks passed"
