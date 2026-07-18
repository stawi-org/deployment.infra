#!/usr/bin/env bash
# Terminate live OCI instances that violate fleet policy hard limits.
#
# Fleet allows intentional paid A1 hours (workers 4/24, CP 2/12). This
# script no longer kills VMs merely for exceeding continuous free 2/12.
#
# Strategy:
#   1. Keep A1 instances within fleet ceilings (≤4 OCPU / ≤24 GB each)
#      and at most MAX_NODES=2 per tenancy (prefer smaller+newer keepers).
#   2. Terminate non-A1 shapes, surplus nodes beyond 2, and nodes above
#      fleet ceilings with preserve-boot-volume=false.
#   3. Optionally delete orphan empty VCNs (DELETE_ORPHAN_VCNS=true).
#
# Env:
#   PROFILE, COMPARTMENT_OCID (required)
#   DRY_RUN=true|false (default true)
#   DELETE_ORPHAN_VCNS=true|false (default false)
set -euo pipefail

PROFILE="${PROFILE:?}"
COMPARTMENT_OCID="${COMPARTMENT_OCID:?}"
DRY_RUN="${DRY_RUN:-true}"
DELETE_ORPHAN_VCNS="${DELETE_ORPHAN_VCNS:-false}"
OCI=(oci --profile "$PROFILE")
# Per-instance fleet ceilings (worker max). Continuous free 2/12 is NOT
# a prune criterion — inventory targets 4/24 workers intentionally.
MAX_OCPU_PER_NODE=4
MAX_MEM_PER_NODE=24
MAX_NODES=2

echo "======== prune fleet violators profile=${PROFILE} dry_run=${DRY_RUN} ========"

inst_json=$("${OCI[@]}" compute instance list --compartment-id "$COMPARTMENT_OCID" --all)
# id name state shape ocpus mem created
mapfile -t ALL < <(echo "$inst_json" | jq -r '
  .data[]?
  | select(.["lifecycle-state"] != "TERMINATED")
  | [
      .id,
      .["display-name"],
      .["lifecycle-state"],
      .shape,
      (.["shape-config"].ocpus // 0),
      (.["shape-config"]["memory-in-gbs"] // 0),
      .["time-created"]
    ] | @tsv
')

echo "live instances:"
for row in "${ALL[@]:-}"; do
  [ -z "${row:-}" ] && continue
  IFS=$'\t' read -r id name state shape ocpus mem created <<<"$row"
  echo "  ${name} ocpu=${ocpus} mem=${mem} state=${state} created=${created} id=${id}"
done

# Select keepers: greedy smallest-first that stay within free envelope.
# Sort by ocpus asc, mem asc, created desc (prefer newer when equal size).
mapfile -t SORTED < <(printf '%s\n' "${ALL[@]:-}" | sort -t$'\t' -k5,5n -k6,6n -k7,7r)

keep_ids=()
keep_ocpu=0
keep_mem=0
keep_count=0
term_rows=()

for row in "${SORTED[@]:-}"; do
  [ -z "${row:-}" ] && continue
  IFS=$'\t' read -r id name state shape ocpus mem created <<<"$row"
  # Non-A1 always terminate
  if [[ "$shape" != "VM.Standard.A1.Flex" ]]; then
    term_rows+=("$row")
    continue
  fi
  new_count=$((keep_count + 1))
  new_ocpu=$(python3 -c "print($keep_ocpu + float('$ocpus'))")
  new_mem=$(python3 -c "print($keep_mem + float('$mem'))")
  # Keep if under node count and this instance itself is within fleet ceilings.
  fits=$(python3 -c "print(1 if $new_count <= $MAX_NODES and float('$ocpus') <= $MAX_OCPU_PER_NODE and float('$mem') <= $MAX_MEM_PER_NODE else 0)")
  if [[ "$fits" == "1" ]]; then
    keep_ids+=("$id")
    keep_count=$new_count
    keep_ocpu=$new_ocpu
    keep_mem=$new_mem
    echo "KEEP  ${name} ocpu=${ocpus} mem=${mem} id=${id}"
  else
    term_rows+=("$row")
    echo "TERM  ${name} ocpu=${ocpus} mem=${mem} id=${id}"
  fi
done

echo "plan: keep=${#keep_ids[@]} terminate=${#term_rows[@]} totals ocpu=${keep_ocpu} mem=${keep_mem}"

for row in "${term_rows[@]:-}"; do
  [ -z "${row:-}" ] && continue
  IFS=$'\t' read -r id name state shape ocpus mem created <<<"$row"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY-RUN would terminate ${id} (${name})"
    continue
  fi
  echo "terminating ${id} (${name}) ..."
  # instance terminate waits on the *work request* states, not instance lifecycle.
  if ! "${OCI[@]}" compute instance terminate \
      --instance-id "$id" \
      --preserve-boot-volume false \
      --force \
      --wait-for-state SUCCEEDED \
      --max-wait-seconds 600; then
    # Fallback: fire-and-forget then poll lifecycle
    if ! "${OCI[@]}" compute instance terminate \
        --instance-id "$id" \
        --preserve-boot-volume false \
        --force; then
      echo "WARN: terminate failed for ${id}"
      continue
    fi
    for _ in $(seq 1 60); do
      st=$("${OCI[@]}" compute instance get --instance-id "$id" 2>/dev/null \
        | jq -r '.data["lifecycle-state"] // "GONE"')
      echo "  ${id} state=${st}"
      [[ "$st" == "TERMINATED" || "$st" == "GONE" ]] && break
      sleep 10
    done
  fi
done

if [[ "$DELETE_ORPHAN_VCNS" == "true" ]]; then
  echo "==== orphan VCN cleanup ===="
  mapfile -t VCNS < <("${OCI[@]}" network vcn list --compartment-id "$COMPARTMENT_OCID" --all \
    | jq -r '.data[]? | select(.["lifecycle-state"]=="AVAILABLE") | .id')
  for vcn in "${VCNS[@]:-}"; do
    [ -z "$vcn" ] && continue
    # Any subnet with private IPs that have vnics?
    busy=0
    while read -r subnet; do
      [ -z "$subnet" ] && continue
      att=$("${OCI[@]}" network private-ip list --subnet-id "$subnet" --all \
        | jq '[.data[]? | select(.["vnic-id"] != null)] | length')
      if [[ "${att:-0}" != "0" ]]; then busy=1; break; fi
    done < <("${OCI[@]}" network subnet list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$vcn" --all \
      | jq -r '.data[]?.id // empty')
    if (( busy )); then
      echo "KEEP VCN ${vcn} (has attachments)"
      continue
    fi
    echo "ORPHAN VCN ${vcn} — tearing down"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "DRY-RUN would delete VCN ${vcn}"
      continue
    fi
    # subnets
    while read -r subnet; do
      [ -z "$subnet" ] && continue
      "${OCI[@]}" network subnet delete --subnet-id "$subnet" --force --wait-for-state TERMINATED --max-wait-seconds 300 || true
    done < <("${OCI[@]}" network subnet list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$vcn" --all | jq -r '.data[]?.id // empty')
    # clear non-default route rules then delete IGWs
    while read -r rt; do
      [ -z "$rt" ] && continue
      name=$("${OCI[@]}" network route-table get --rt-id "$rt" | jq -r '.data["display-name"]')
      if [[ "$name" != Default* ]]; then
        "${OCI[@]}" network route-table update --rt-id "$rt" --route-rules '[]' --force || true
        "${OCI[@]}" network route-table delete --rt-id "$rt" --force || true
      else
        "${OCI[@]}" network route-table update --rt-id "$rt" --route-rules '[]' --force || true
      fi
    done < <("${OCI[@]}" network route-table list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$vcn" --all | jq -r '.data[]?.id // empty')
    while read -r igw; do
      [ -z "$igw" ] && continue
      "${OCI[@]}" network internet-gateway delete --ig-id "$igw" --force --wait-for-state TERMINATED --max-wait-seconds 180 || true
    done < <("${OCI[@]}" network internet-gateway list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$vcn" --all | jq -r '.data[]?.id // empty')
    while read -r sl; do
      [ -z "$sl" ] && continue
      name=$("${OCI[@]}" network security-list get --security-list-id "$sl" | jq -r '.data["display-name"]')
      [[ "$name" == Default* ]] && continue
      "${OCI[@]}" network security-list delete --security-list-id "$sl" --force || true
    done < <("${OCI[@]}" network security-list list --compartment-id "$COMPARTMENT_OCID" --vcn-id "$vcn" --all | jq -r '.data[]?.id // empty')
    "${OCI[@]}" network vcn delete --vcn-id "$vcn" --force --wait-for-state TERMINATED --max-wait-seconds 300 || true
  done
fi

echo "done"
