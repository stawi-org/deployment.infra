#!/usr/bin/env bash
# Per-node recovery actions.
#
# Inputs (via env, set by the node-recovery workflow):
#   NODE_KEY   inventory node_key (e.g. kubernetes-controlplane-api-2)
#   ACTION     diagnose | reboot | reapply | reinstall
#
# Works by reading the layer 01/02/03 tfstates from R2 to resolve the
# node's IP + credentials, then shelling out to talosctl (for
# diagnose/reboot/reapply) or the R2 state-writer path (for reinstall).
#
# Exit codes: 0 on success, 1 on error. Every action is idempotent
# except reinstall (which re-images the disk).
set -euo pipefail

: "${NODE_KEY:?set NODE_KEY}"
: "${ACTION:?set ACTION}"
: "${AWS_ACCESS_KEY_ID:?set}"
: "${AWS_SECRET_ACCESS_KEY:?set}"
: "${R2_ENDPOINT:?set}"

BUCKET="cluster-tofu-state"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# ----- Pull the three tfstates we need -------------------------------
for key in production/01-contabo-infra.tfstate \
           production/02-oracle-infra.tfstate \
           production/03-talos.tfstate; do
  aws s3 cp "s3://${BUCKET}/${key}" "$tmp/$(basename "$key")" \
    --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null 2>&1 || true
done

# ----- Resolve the node's (provider, ipv4, private_ipv4, provider_data) -
NODE_JSON=$(python3 - <<PY "$tmp" "$NODE_KEY"
import json, sys, pathlib
tmp, key = sys.argv[1], sys.argv[2]
found = None
for f in ("01-contabo-infra.tfstate", "02-oracle-infra.tfstate"):
    p = pathlib.Path(tmp) / f
    if not p.exists():
        continue
    doc = json.loads(p.read_text())
    nodes = (doc.get("outputs", {}) or {}).get("nodes", {}).get("value", {}) or {}
    if key in nodes:
        n = nodes[key]
        found = {
            "provider":     n.get("provider"),
            "ipv4":         n.get("ipv4"),
            "private_ipv4": n.get("private_ipv4") or n.get("ipv4"),
            "bastion_id":   n.get("bastion_id"),
        }
        break
print(json.dumps(found or {}))
PY
)
PROVIDER=$(jq -r '.provider // empty' <<<"$NODE_JSON")
NODE_IP=$(jq -r '.ipv4 // empty' <<<"$NODE_JSON")
if [[ -z "$PROVIDER" || -z "$NODE_IP" ]]; then
  echo "::error::node_key $NODE_KEY not found in any tfstate.outputs.nodes"
  exit 1
fi
echo "::notice::node=$NODE_KEY provider=$PROVIDER ip=$NODE_IP action=$ACTION"

# ----- Extract talosconfig -------------------------------------------
if [[ -s "$tmp/03-talos.tfstate" ]]; then
  jq -r '.outputs.talosconfig.value' "$tmp/03-talos.tfstate" > "$tmp/talosconfig"
  export TALOSCONFIG="$tmp/talosconfig"
  chmod 0600 "$tmp/talosconfig"
fi

# ----- Actions -------------------------------------------------------
case "$ACTION" in
  diagnose)
    echo "::group::talosctl version"
    talosctl -n "$NODE_IP" -e "$NODE_IP" version || true
    echo "::endgroup::"
    echo "::group::talosctl service list"
    talosctl -n "$NODE_IP" -e "$NODE_IP" services || true
    echo "::endgroup::"
    echo "::group::talosctl get members (etcd)"
    talosctl -n "$NODE_IP" -e "$NODE_IP" etcd members || true
    echo "::endgroup::"
    echo "::group::talosctl get addresses (link status)"
    talosctl -n "$NODE_IP" -e "$NODE_IP" get addresses || true
    echo "::endgroup::"
    echo "::group::talosctl dmesg (last 200 lines)"
    talosctl -n "$NODE_IP" -e "$NODE_IP" dmesg 2>/dev/null | tail -200 || true
    echo "::endgroup::"
    ;;

  reboot)
    echo "Rebooting $NODE_KEY ($NODE_IP) …"
    talosctl -n "$NODE_IP" -e "$NODE_IP" reboot --wait --timeout 10m
    echo "Waiting for :50000 …"
    for i in $(seq 1 60); do
      if timeout 3 bash -c "echo > /dev/tcp/$NODE_IP/50000" 2>/dev/null; then
        echo "::notice::back up after $((i * 5))s"
        exit 0
      fi
      sleep 5
    done
    echo "::error::$NODE_IP:50000 did not recover in 5 min"
    exit 1
    ;;

  reapply)
    # Pull the per-node config we last wrote to R2 at
    # <provider>/<account>/<talos_version>/<node_key>.yaml and re-apply.
    TALOS_VERSION=$(awk -F'"' '/^talos_version[[:space:]]*=/ {print $2; exit}' tofu/shared/versions.auto.tfvars)
    # Recover the account from the node_key: convention is that the
    # account is embedded in the operator-declared node_key. Simpler:
    # search all accounts under the provider for a matching key.
    CONFIG_LOCAL="$tmp/${NODE_KEY}.yaml"
    found_key=""
    while IFS= read -r cand; do
      if aws s3 cp "s3://${BUCKET}/${cand}" "$CONFIG_LOCAL" \
          --endpoint-url "$R2_ENDPOINT" --region us-east-1 >/dev/null 2>&1; then
        found_key="$cand"
        break
      fi
    done < <(
      aws s3 ls "s3://${BUCKET}/production/inventory/${PROVIDER}/" \
        --endpoint-url "$R2_ENDPOINT" --region us-east-1 --recursive \
        | awk -v v="${TALOS_VERSION}" -v n="${NODE_KEY}.yaml" '$0 ~ "/"v"/"n"$" {print $4}'
    )
    if [[ -z "$found_key" ]]; then
      echo "::error::no per-node config at <acct>/${TALOS_VERSION}/${NODE_KEY}.yaml under inventory/${PROVIDER}/"
      exit 1
    fi
    echo "::notice::reapplying $found_key → $NODE_IP"
    talosctl -n "$NODE_IP" -e "$NODE_IP" apply-config --file "$CONFIG_LOCAL" --mode=reboot
    ;;

  reinstall)
    case "$PROVIDER" in
      contabo)
        echo "::notice::For Contabo, bump force_reinstall_generation in tofu/layers/01-contabo-infra/terraform.tfvars"
        echo "          and trigger tofu-apply. That wipes the disk and re-flashes Talos."
        echo "          (Per-node reinstall not wired yet — ensure_image runs for every node at once.)"
        exit 1
        ;;
      oracle)
        echo "::notice::For OCI, bump force_image_generation in tofu/layers/02-oracle-infra/terraform.tfvars"
        echo "          and trigger tofu-apply. That rebuilds the custom image and replaces the instance."
        exit 1
        ;;
      *)
        echo "::error::reinstall action is not implemented for provider $PROVIDER"
        exit 1
        ;;
    esac
    ;;

  *)
    echo "::error::unknown ACTION: $ACTION"
    exit 1
    ;;
esac
