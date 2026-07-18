#!/usr/bin/env bash
# Live-audit one OCI tenancy against continuous Always Free caps.
#
# Hard failures: non-A1 shape, >2 nodes, ocpu>2, mem>12, boot>196 usable
# (200 hard − 4 GB buffer), >2 VCNs, object storage over free, etc.
#
# Expects:
#   PROFILE              OCI CLI config profile (WIF or api_key)
#   COMPARTMENT_OCID     root or working compartment to scan
#   TENANCY_OCID         tenancy OCID (for limit checks / reporting)
#   ACCOUNT              logical account key (label only)
#
# Exit 0 if no hard violations, 1 if any hard violation.
set -euo pipefail

PROFILE="${PROFILE:?}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:?}"
TENANCY_OCID="${TENANCY_OCID:-$COMPARTMENT_OCID}"
ACCOUNT="${ACCOUNT:-$PROFILE}"
OCI=(oci --profile "$PROFILE")

MAX_OCPU=2
MAX_MEM=12
MAX_BOOT_HARD=200
MAX_BOOT_USABLE=196
BOOT_BUFFER=4
MAX_NODES=2
MAX_VCN=2
MAX_OBJECT_GB=20
A1_SHAPE="VM.Standard.A1.Flex"

violations=0
note() { echo "  - $*"; }
fail() { echo "  FAIL: $*"; violations=$((violations + 1)); }
ok()   { echo "  OK: $*"; }

echo "======== live free-tier audit: ${ACCOUNT} ========"
echo "tenancy=${TENANCY_OCID}"
echo "compartment=${COMPARTMENT_OCID}"
echo "profile=${PROFILE}"

# --- Compute instances ---
inst_json=$("${OCI[@]}" compute instance list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || echo '{"data":[]}')
# Include running + stopped + provisioning (billable). Exclude TERMINATED.
mapfile -t rows < <(echo "$inst_json" | jq -r '
  .data[]?
  | select(.["lifecycle-state"] != "TERMINATED")
  | [
      .["display-name"],
      .["lifecycle-state"],
      .shape,
      (.["shape-config"].ocpus // 0),
      (.["shape-config"]["memory-in-gbs"] // 0),
      .id
    ] | @tsv
')

node_count=${#rows[@]}
ocpu_total=0
mem_total=0
echo "instances (${node_count}):"
for row in "${rows[@]:-}"; do
  [ -z "${row:-}" ] && continue
  IFS=$'\t' read -r name state shape ocpus mem id <<<"$row"
  echo "  ${name} state=${state} shape=${shape} ocpu=${ocpus} mem=${mem}"
  ocpu_total=$(python3 -c "print($ocpu_total + float('$ocpus'))")
  mem_total=$(python3 -c "print($mem_total + float('$mem'))")
  if [[ "$shape" != "$A1_SHAPE" ]]; then
    fail "instance ${name} shape ${shape} is not Always Free A1"
  fi
done

# ocpu/mem as integers for display
ocpu_i=$(python3 -c "print(int(float('$ocpu_total')))")
mem_i=$(python3 -c "print(int(float('$mem_total')))")

if (( node_count > MAX_NODES )); then
  fail "instance count ${node_count} > ${MAX_NODES}"
else
  ok "instance count ${node_count} ≤ ${MAX_NODES}"
fi
if python3 -c "import sys; sys.exit(0 if float('$ocpu_total') <= $MAX_OCPU else 1)"; then
  ok "ocpu total ${ocpu_total} ≤ continuous free ${MAX_OCPU}"
else
  fail "ocpu total ${ocpu_total} > continuous free ${MAX_OCPU}"
fi
if python3 -c "import sys; sys.exit(0 if float('$mem_total') <= $MAX_MEM else 1)"; then
  ok "memory total ${mem_total} GB ≤ continuous free ${MAX_MEM}"
else
  fail "memory total ${mem_total} GB > continuous free ${MAX_MEM}"
fi

# --- Boot + block volumes across ADs ---
boot_total=0
block_total=0
ads=$("${OCI[@]}" iam availability-domain list --compartment-id "$TENANCY_OCID" --query 'data[*].name' --raw-output 2>/dev/null || echo '[]')
while read -r ad; do
  [ -z "$ad" ] && continue
  bj=$("${OCI[@]}" bv boot-volume list --compartment-id "$COMPARTMENT_OCID" --availability-domain "$ad" --all 2>/dev/null || echo '{"data":[]}')
  while read -r line; do
    [ -z "$line" ] && continue
    IFS=$'\t' read -r name size state <<<"$line"
    echo "  boot ${name} ${size}GB ${state} (${ad})"
    boot_total=$((boot_total + size))
  done < <(echo "$bj" | jq -r '
    .data[]? | select(.["lifecycle-state"] != "TERMINATED") |
    [.["display-name"], (.["size-in-gbs"]//0), .["lifecycle-state"]] | @tsv
  ')
done < <(echo "$ads" | jq -r '.[]?')

vj=$("${OCI[@]}" bv volume list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || echo '{"data":[]}')
while read -r line; do
  [ -z "$line" ] && continue
  IFS=$'\t' read -r name size state <<<"$line"
  echo "  block ${name} ${size}GB ${state}"
  block_total=$((block_total + size))
done < <(echo "$vj" | jq -r '
  .data[]? | select(.["lifecycle-state"] != "TERMINATED") |
  [.["display-name"], (.["size-in-gbs"]//0), .["lifecycle-state"]] | @tsv
')

vol_total=$((boot_total + block_total))
if (( vol_total > MAX_BOOT_HARD )); then
  fail "block/boot total ${vol_total} GB > hard free cap ${MAX_BOOT_HARD}"
elif (( vol_total > MAX_BOOT_USABLE )); then
  fail "block/boot total ${vol_total} GB > usable ${MAX_BOOT_USABLE} (${MAX_BOOT_HARD} − ${BOOT_BUFFER} GB buffer)"
else
  ok "block/boot total ${vol_total} GB (boot=${boot_total} block=${block_total}) ≤ usable ${MAX_BOOT_USABLE} (buffer ${BOOT_BUFFER} GB under ${MAX_BOOT_HARD})"
fi

# --- VCNs ---
vcn_json=$("${OCI[@]}" network vcn list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || echo '{"data":[]}')
vcn_count=$(echo "$vcn_json" | jq '[.data[]? | select(.["lifecycle-state"]=="AVAILABLE")] | length')
echo "$vcn_json" | jq -r '.data[]? | "  vcn \(.["display-name"]) \(.["lifecycle-state"]) \(.id)"'
if (( vcn_count > MAX_VCN )); then
  fail "VCN count ${vcn_count} > Always Free max ${MAX_VCN} (free-tier tenancies)"
else
  ok "VCN count ${vcn_count} ≤ ${MAX_VCN}"
fi

# --- Object storage ---
ns=$("${OCI[@]}" os ns get --query 'data' --raw-output 2>/dev/null || true)
obj_bytes=0
if [[ -n "${ns:-}" ]]; then
  buckets=$("${OCI[@]}" os bucket list --namespace-name "$ns" --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || echo '{"data":[]}')
  while read -r b; do
    [ -z "$b" ] && continue
    size=$("${OCI[@]}" os object list --namespace-name "$ns" --bucket-name "$b" --all 2>/dev/null \
      | jq '[.data[]?.size // 0] | add // 0' || echo 0)
    count=$("${OCI[@]}" os object list --namespace-name "$ns" --bucket-name "$b" --all 2>/dev/null \
      | jq '[.data[]?] | length' || echo 0)
    echo "  bucket ${b} objects=${count} bytes=${size}"
    obj_bytes=$((obj_bytes + size))
  done < <(echo "$buckets" | jq -r '.data[]?.name // empty')
fi
obj_gb=$(python3 -c "print(round($obj_bytes/1024/1024/1024, 3))")
if python3 -c "import sys; sys.exit(0 if $obj_bytes <= $MAX_OBJECT_GB * 1024**3 else 1)"; then
  ok "object storage ~${obj_gb} GB ≤ ${MAX_OBJECT_GB}"
else
  fail "object storage ~${obj_gb} GB > ${MAX_OBJECT_GB}"
fi

# --- Reserved public IPs (Always Free allows 2) ---
rip=$("${OCI[@]}" network public-ip list --compartment-id "$COMPARTMENT_OCID" --scope REGION --lifetime RESERVED --all 2>/dev/null || echo '{"data":[]}')
rip_count=$(echo "$rip" | jq '[.data[]?] | length // 0')
rip_count=${rip_count:-0}
echo "$rip" | jq -r '.data[]? | "  reserved-ip \(.["display-name"]) \(.["ip-address"]) \(.["lifecycle-state"]) assigned=\(.["assigned-entity-id"]//"-")"'
if (( rip_count > 2 )); then
  fail "reserved public IPs ${rip_count} > 2"
else
  ok "reserved public IPs ${rip_count} ≤ 2"
fi

# --- Load balancers ---
lb=$("${OCI[@]}" lb load-balancer list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || echo '{"data":[]}')
lb_count=$(echo "$lb" | jq '[.data[]?] | length // 0' 2>/dev/null || echo 0)
lb_count=${lb_count:-0}
if (( lb_count > 1 )); then
  fail "load balancers ${lb_count} > 1 Always Free flexible LB"
else
  ok "load balancers ${lb_count} ≤ 1"
fi

# --- Autonomous DB ---
adb=$("${OCI[@]}" db autonomous-database list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || echo '{"data":[]}')
adb_nonfree=$(echo "$adb" | jq '[.data[]? | select(.["lifecycle-state"]!="TERMINATED" and (.["is-free-tier"]!=true))] | length // 0' 2>/dev/null || echo 0)
adb_free=$(echo "$adb" | jq '[.data[]? | select(.["lifecycle-state"]!="TERMINATED" and .["is-free-tier"]==true)] | length // 0' 2>/dev/null || echo 0)
adb_nonfree=${adb_nonfree:-0}
adb_free=${adb_free:-0}
if (( adb_nonfree > 0 )); then
  fail "non-free Autonomous DB count ${adb_nonfree}"
else
  ok "Autonomous DB free=${adb_free} non-free=${adb_nonfree}"
fi

# --- Custom images (compartment-owned only) ---
imgs=$("${OCI[@]}" compute image list --compartment-id "$COMPARTMENT_OCID" --all 2>/dev/null || echo '{"data":[]}')
img_count=$(echo "$imgs" | jq --arg c "$COMPARTMENT_OCID" --arg t "$TENANCY_OCID" '
  [.data[]? | select((.["compartment-id"]==$c or .["compartment-id"]==$t) and (.["lifecycle-state"]=="AVAILABLE"))] | length
')
echo "$imgs" | jq -r --arg c "$COMPARTMENT_OCID" --arg t "$TENANCY_OCID" '
  .data[]? | select((.["compartment-id"]==$c or .["compartment-id"]==$t) and (.["lifecycle-state"]=="AVAILABLE")) |
  "  custom-image \(.["display-name"]) \(.["size-in-mbs"]//0)MB"
'
note "custom images in compartment: ${img_count} (prune stale Talos images to save hygiene)"

echo "--------"
echo "summary account=${ACCOUNT} nodes=${node_count} ocpu=${ocpu_total} mem=${mem_total} boot+block=${vol_total}GB vcns=${vcn_count} object_gb=${obj_gb} violations=${violations}"
if (( violations > 0 )); then
  echo "RESULT: FAIL (${violations} violation(s))"
  exit 1
fi
echo "RESULT: OK"
exit 0
