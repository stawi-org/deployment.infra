#!/usr/bin/env bash
# Post-apply cluster health check. Pulls kubeconfig + talosconfig from
# the layer-03 tfstate in R2, runs a short battery of checks, and
# summarises pass/fail. Every check writes a block so a failed one
# shows which output triggered it.
#
# Exit codes: 0 = all checks passed, 1 = at least one check failed.
#
# Requires: aws CLI, jq, kubectl, talosctl, flux. R2 creds in env.
set -uo pipefail

: "${AWS_ACCESS_KEY_ID:?set}"
: "${AWS_SECRET_ACCESS_KEY:?set}"
: "${R2_ENDPOINT:?set}"

TFSTATE_KEY="production/03-talos.tfstate"
BUCKET="cluster-tofu-state"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "::group::Fetch tfstate + extract credentials"
aws s3 cp "s3://${BUCKET}/${TFSTATE_KEY}" "$tmp/03-talos.tfstate" \
  --endpoint-url "$R2_ENDPOINT" --region us-east-1

jq -r '.outputs.kubeconfig_raw.value' "$tmp/03-talos.tfstate" > "$tmp/kubeconfig"
jq -r '.outputs.talosconfig.value' "$tmp/03-talos.tfstate" > "$tmp/talosconfig"
if [[ ! -s "$tmp/kubeconfig" || "$(head -c 10 "$tmp/kubeconfig")" == "null" ]]; then
  echo "::error::kubeconfig_raw output missing from layer-03 tfstate"
  exit 1
fi
chmod 0600 "$tmp/kubeconfig" "$tmp/talosconfig"
export KUBECONFIG="$tmp/kubeconfig"
export TALOSCONFIG="$tmp/talosconfig"
echo "::endgroup::"

FAIL=0
pass() { echo "  PASS: $*"; }
fail() { echo "::error::FAIL: $*"; FAIL=$((FAIL + 1)); }

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
echo "::group::etcd member health (talosctl)"
CP_IPS=$(jq -r '
  .outputs.endpoints.value // [] | .[]
' "$tmp/03-talos.tfstate" 2>/dev/null)
if [[ -z "$CP_IPS" ]]; then
  # Fallback: pull from the output used by apply (first direct CP)
  CP_IPS=$(jq -r '.outputs.kubernetes_endpoint.value' "$tmp/03-talos.tfstate" \
    | sed -E 's|^https?://([^:]+).*|\1|')
fi
FIRST_CP=$(echo "$CP_IPS" | head -1)
if [[ -z "$FIRST_CP" ]]; then
  fail "could not resolve any CP IP from tfstate"
else
  echo "  probing etcd on $FIRST_CP"
  if talosctl -n "$FIRST_CP" -e "$FIRST_CP" etcd members 2>&1; then
    pass "etcd members query succeeded"
  else
    fail "etcd members query failed on $FIRST_CP"
  fi
fi
echo "::endgroup::"

# ----- 5. flux reconciled --------------------------------------------
echo "::group::flux reconciliation (flux get all)"
if flux check 2>&1; then
  pass "flux check"
else
  fail "flux check reported problems"
fi
echo
if flux get all -A --status-selector=ready=true 2>&1; then
  pass "flux resources ready"
else
  fail "some flux resources not ready"
fi
echo "::endgroup::"

echo
if [[ "$FAIL" -gt 0 ]]; then
  echo "::error::cluster-health: $FAIL check(s) failed"
  exit 1
fi
echo "::notice::cluster-health: all checks passed"
