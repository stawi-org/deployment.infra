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
# `omnictl kubeconfig --service-account` issues a kubeconfig backed by
# a Kubernetes ServiceAccount token rather than the default Omni-OIDC
# exec plugin. The OIDC form needs the `kubectl-oidc-login` plugin in
# PATH AND a user-level browser flow on first use — both of which fail
# in CI ("error: unknown command \"oidc-login\" for \"kubectl\"").
# The SA form is token-based, headless, and runs through Omni's
# workload-proxy (no direct CP IP access required).
#
# `--user` sets the kubeconfig context name (cosmetic). `--groups
# system:masters` gives full cluster-admin (acceptable for a
# read-only diagnostic; tighten if this script ever mutates state).
if ! omnictl kubeconfig --cluster "$OMNI_CLUSTER" --service-account \
     --user cluster-health --groups system:masters --force "$tmp/kubeconfig" 2>&1; then
  echo "::error::omnictl kubeconfig failed — cluster $OMNI_CLUSTER may not exist or SA auth is broken"
  exit 1
fi
# talosconfig issued via Omni's siderolink proxy. Break-glass form
# would bypass the proxy and pre-populate nodes/endpoints, but
# requires elevated SA permissions we don't grant by default
# (`PermissionDenied: not allowed`). The proxied form is fine for
# diagnostics: when apid is unreachable through the WG mesh that's
# itself a finding worth surfacing in the etcd-members probe below.
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

# ----- 0. CNI status (informational, never gates) --------------------
# The original early-exit gate skipped every other check when the CNI
# wasn't fully ready — useful when the cluster was running but CNI
# was flapping, but it makes this workflow useless for diagnosing
# fresh-bootstrap state. Keep CNI as an informational signal and let
# the per-check timeouts (10–30s each) handle the case where downstream
# probes hang against an apiserver that's still warming up. Total
# worst-case runtime stays under 3 min.
echo "::group::CNI status (informational)"
FLANNEL_DS_JSON=$(timeout 20 kubectl -n kube-system get ds kube-flannel \
  --request-timeout=10s -o json 2>/dev/null || echo '{}')
DESIRED=$(jq -r '.status.desiredNumberScheduled // 0' <<<"$FLANNEL_DS_JSON")
READY=$(jq -r '.status.numberReady // 0' <<<"$FLANNEL_DS_JSON")
if [[ "$DESIRED" == "0" ]]; then
  echo "  INFO: kube-flannel daemonset not found (cluster may still be bootstrapping or running a non-default CNI)"
  echo "  daemonsets in kube-system:"
  timeout 10 kubectl -n kube-system get ds --request-timeout=10s 2>&1 | sed 's/^/    /' || true
elif [[ "$READY" != "$DESIRED" ]]; then
  echo "  INFO: Flannel not fully ready ($READY/$DESIRED) — proceeding with checks"
else
  echo "  Flannel ready ($READY/$DESIRED)"
fi
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

  # Per-node InternalIPs (both v4 + v6) and podCIDRs — gives us the
  # actual dual-stack picture. `kubectl get -o wide` only prints one
  # IP per family per row, so we have to fall back to JSON to see all
  # addresses.
  echo
  echo "Per-node addresses + podCIDRs (dual-stack snapshot):"
  jq -r '
    .items[] | "  \(.metadata.name):"
      + " addrs=[" + ([.status.addresses[]? | "\(.type)=\(.address)"] | join(",")) + "]"
      + " podCIDRs=" + (.spec.podCIDRs // [.spec.podCIDR // ""] | tostring)
  ' <<<"$NODES_JSON"
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
# Discover CP machine IDs by intersecting `omnictl get
# clustermachinestatus` (rows for the cluster's machines) with
# `omnictl get machinelabels` (filtered by the
# node.antinvestor.io/role=controlplane label tofu applies). talosctl
# under the proxied talosconfig reaches each CP's apid via Omni's
# siderolink mesh, addressed by Omni Machine ID rather than a public
# IP. Hard 30s cap — if every CP is unreachable, talosctl otherwise
# stalls for ~10 min on its own connection retries.
echo "::group::etcd member health (talosctl)"
CP_IDS=$(omnictl get machinelabels -o json 2>/dev/null \
  | jq -rs '
      flatten
      | map(select(
          .metadata.labels["node.antinvestor.io/role"] == "controlplane"
        ) | .metadata.id)
      | .[]' \
  | head -3)
if [[ -z "$CP_IDS" ]]; then
  fail "no CP machines found via labels — cluster.tf labelling may not have run"
else
  echo "  CP machine IDs:"; echo "$CP_IDS" | sed 's/^/    /'
  # First reachable CP wins; iterate to avoid one bad CP failing
  # the whole probe.
  ETCD_OK=0
  while read -r CP_ID; do
    [[ -z "$CP_ID" ]] && continue
    echo "  probing etcd via $CP_ID"
    if timeout 30 talosctl -n "$CP_ID" etcd members 2>&1; then
      pass "etcd members query succeeded via $CP_ID"
      ETCD_OK=1
      break
    fi
    echo "  -> failed via $CP_ID, trying next"
  done <<< "$CP_IDS"
  [[ "$ETCD_OK" -eq 0 ]] && fail "etcd members query failed against every CP"
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
