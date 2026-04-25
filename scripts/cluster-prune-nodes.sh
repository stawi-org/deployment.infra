#!/usr/bin/env bash
# Delete stale kubernetes Node objects left behind by earlier naming
# generations. Kubelet registers under the current hostname on every
# Talos config apply, so renaming a node via moved{} + new-config
# leaves the OLD Node object NotReady in kube-apiserver — flux
# schedulers keep trying to place pods on ghosts.
#
# Strategy: compare `kubectl get nodes` against the current inventory
# (derived from layer 01/02-oracle/02-onprem tfstate outputs). Any
# kubelet Node that's (a) NotReady AND (b) not in inventory is deleted.
#
# Safe: nodes listed in inventory are never touched, even if NotReady
# (could be transient). Only ghost Node objects get pruned.
#
# Requires: aws CLI, jq, kubectl. R2 creds in env.
set -uo pipefail

: "${AWS_ACCESS_KEY_ID:?set}"
: "${AWS_SECRET_ACCESS_KEY:?set}"
: "${R2_ENDPOINT:?set}"

BUCKET="cluster-tofu-state"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "::group::Fetch kubeconfig from layer 03 tfstate"
aws s3 cp "s3://${BUCKET}/production/03-talos.tfstate" "$tmp/03-talos.tfstate" \
  --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null
jq -r '.outputs.kubeconfig_raw.value' "$tmp/03-talos.tfstate" > "$tmp/kubeconfig"
chmod 0600 "$tmp/kubeconfig"
export KUBECONFIG="$tmp/kubeconfig"
echo "::endgroup::"

echo "::group::Resolve inventory node names (tfstate outputs.nodes)"
INVENTORY=()
for tfstate in production/01-contabo-infra.tfstate \
               production/02-oracle-infra.tfstate \
               production/02-onprem-infra.tfstate; do
  f="$tmp/$(basename "$tfstate")"
  aws s3 cp "s3://${BUCKET}/${tfstate}" "$f" \
    --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null 2>&1 || continue
  while IFS= read -r name; do
    [[ -n "$name" ]] && INVENTORY+=("$name")
  done < <(jq -r '.outputs.nodes.value // {} | keys[]' "$f" 2>/dev/null)
done
printf 'inventory node_key: %s\n' "${INVENTORY[@]}"
echo "::endgroup::"

echo "::group::Prune stale kubelet Node objects"
NODES_JSON=$(kubectl get nodes -o json --request-timeout=10s)
TO_DELETE=()
while IFS= read -r entry; do
  name=${entry%%|*}
  ready=${entry##*|}
  # Skip if kubelet says Ready.
  [[ "$ready" == "True" ]] && continue
  # Skip if in inventory — may be transiently NotReady.
  in_inv=false
  for inv in "${INVENTORY[@]}"; do
    [[ "$inv" == "$name" ]] && { in_inv=true; break; }
  done
  $in_inv && continue
  TO_DELETE+=("$name")
done < <(
  jq -r '.items[] | "\(.metadata.name)|\((.status.conditions // [])
    | map(select(.type == "Ready")) | first.status)"' <<<"$NODES_JSON"
)

if [[ ${#TO_DELETE[@]} -eq 0 ]]; then
  echo "::notice::no stale Node objects — cluster and inventory agree"
else
  for name in "${TO_DELETE[@]}"; do
    echo "::notice::deleting stale Node $name"
    kubectl delete node "$name" --request-timeout=15s
  done
fi
echo "::endgroup::"

echo "::group::Post-prune node list"
kubectl get nodes -o wide --request-timeout=10s
echo "::endgroup::"
