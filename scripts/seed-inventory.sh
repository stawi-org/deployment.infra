#!/usr/bin/env bash
# Seeds the R2 inventory/ tree for the first apply.
#
# Modes:
#   --dry-run   : write to --output-dir instead of R2 (used by tests & CI preview)
#   (default)   : sync to s3://cluster-tofu-state/production/inventory/
#
# Flags:
#   --output-dir PATH         dry-run destination root (default /tmp/seed-output)
#   --bootstrap PATH          fallback instance IDs (YAML) for unresolvable Contabo nodes
#   --contabo-account ACCT    account key
#   --contabo-node NAME       repeatable
#   --contabo-list-cmd CMD    command that prints Contabo instances JSON
#   --oci-account ACCT        repeatable via separate invocations
#   --oci-node NAME           repeatable
#   --oci-list-cmd CMD        command that prints OCI instances JSON
set -euo pipefail

DRY_RUN=false
OUTDIR=""
BOOTSTRAP=""
CONTABO_ACCT=""
CONTABO_NODES=()
CONTABO_LIST_CMD=""
OCI_ACCT=""
OCI_NODES=()
OCI_LIST_CMD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --output-dir) OUTDIR=$2; shift 2 ;;
    --bootstrap) BOOTSTRAP=$2; shift 2 ;;
    --contabo-account) CONTABO_ACCT=$2; shift 2 ;;
    --contabo-node) CONTABO_NODES+=("$2"); shift 2 ;;
    --contabo-list-cmd) CONTABO_LIST_CMD=$2; shift 2 ;;
    --oci-account) OCI_ACCT=$2; shift 2 ;;
    --oci-node) OCI_NODES+=("$2"); shift 2 ;;
    --oci-list-cmd) OCI_LIST_CMD=$2; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

: "${OUTDIR:?--output-dir required (use /tmp/seed-output for non-dry-run)}"
here="$(cd "$(dirname "$0")" && pwd)"
export PYTHONPATH="$here/lib${PYTHONPATH+:$PYTHONPATH}"

seed_contabo() {
  local acct=$1 ; shift
  local wanted=("$@")
  local list_json
  list_json=$("$CONTABO_LIST_CMD")
  export _LIST_JSON="$list_json"
  python3 - "$acct" "$BOOTSTRAP" "$OUTDIR" "${wanted[@]}" <<'PY'
import json, os, sys, yaml
from inventory_yaml import render_nodes_yaml, render_state_yaml

acct, bootstrap_path, outdir, *wanted = sys.argv[1:]
instances = json.loads(os.environ["_LIST_JSON"])["instances"]
by_name = {}
for inst in instances:
    by_name.setdefault(inst["displayName"], []).append(inst)

resolved = {}
for name in wanted:
    matches = by_name.get(name, [])
    if len(matches) == 1:
        ipc = matches[0].get("ipConfig", {})
        resolved[name] = {
            "contabo_instance_id": str(matches[0]["instanceId"]),
            "ipv4": (ipc.get("v4") or [{}])[0].get("ip"),
            "ipv6": (ipc.get("v6") or [{}])[0].get("ip"),
        }
    elif len(matches) > 1:
        print(f"ERROR: multiple Contabo instances match {name!r}. Disambiguate manually.", file=sys.stderr)
        sys.exit(3)
    else:
        if bootstrap_path and os.path.exists(bootstrap_path):
            data = yaml.safe_load(open(bootstrap_path)) or {}
            fallback = data.get("contabo", {}).get(acct, {}).get(name)
            if fallback:
                resolved[name] = dict(fallback)
                continue
        print(f"ERROR: Contabo node {name!r} not resolvable by name or bootstrap.", file=sys.stderr)
        sys.exit(4)

base = os.path.join(outdir, "contabo", acct)
os.makedirs(base, exist_ok=True)
open(os.path.join(base, "nodes.yaml"), "w").write(
    render_nodes_yaml("contabo", acct, {"labels": {}, "annotations": {}},
                      {name: {"role": "controlplane"} for name in wanted})
)
open(os.path.join(base, "state.yaml"), "w").write(
    render_state_yaml("contabo", acct, resolved)
)
PY
}

seed_oci() {
  local acct=$1 ; shift
  local wanted=("$@")
  local list_json
  list_json=$("$OCI_LIST_CMD")
  export _LIST_JSON="$list_json"
  python3 - "$acct" "$OUTDIR" "${wanted[@]}" <<'PY'
import json, os, sys, yaml
from inventory_yaml import render_nodes_yaml, render_state_yaml

acct, outdir, *wanted = sys.argv[1:]
data = json.loads(os.environ["_LIST_JSON"])
# OCI CLI output uses either top-level list or {"data":[...]}
instances = data["data"] if isinstance(data, dict) and "data" in data else data

by_name = {}
for inst in instances:
    by_name.setdefault(inst.get("display-name") or inst.get("displayName"), []).append(inst)

resolved = {}
for name in wanted:
    matches = by_name.get(name, [])
    if len(matches) == 1:
        resolved[name] = {
            "oci_instance_ocid": matches[0]["id"],
            "shape": matches[0].get("shape"),
            "region": matches[0].get("region"),
        }
    elif len(matches) > 1:
        print(f"ERROR: multiple OCI instances match {name!r}.", file=sys.stderr)
        sys.exit(3)
    # Missing OCI node is OK — tofu will create it on apply.

base = os.path.join(outdir, "oracle", acct)
os.makedirs(base, exist_ok=True)
open(os.path.join(base, "nodes.yaml"), "w").write(
    render_nodes_yaml("oracle", acct, {"labels": {}, "annotations": {}},
                      {name: {"role": "worker"} for name in wanted})
)
open(os.path.join(base, "state.yaml"), "w").write(
    render_state_yaml("oracle", acct, resolved)
)
PY
}

[[ -n "$CONTABO_ACCT" ]] && seed_contabo "$CONTABO_ACCT" "${CONTABO_NODES[@]}"
[[ -n "$OCI_ACCT" ]] && seed_oci "$OCI_ACCT" "${OCI_NODES[@]}"

if [[ "$DRY_RUN" == false ]]; then
  : "${R2_ENDPOINT_URL:?R2_ENDPOINT_URL required for non-dry-run}"
  aws s3 sync "$OUTDIR" "s3://cluster-tofu-state/production/inventory/" \
    --endpoint-url "$R2_ENDPOINT_URL" --region us-east-1
fi
