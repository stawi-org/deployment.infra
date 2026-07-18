#!/usr/bin/env bash
# Terminate live OCI instances that push a tenancy over continuous Always Free.
#
# Strategy:
#   1. Keep the largest free-legal set (≤2 nodes, ≤2 OCPU, ≤12 GB total).
#   2. Prefer smaller+newer keepers when packing the free envelope.
#   3. Terminate the rest with preserve-boot-volume=false.
#   4. Optionally delete orphan empty VCNs (DELETE_ORPHAN_VCNS=true).
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
MAX_OCPU=2
MAX_MEM=12
MAX_NODES=2

echo "======== prune free-tier violators profile=${PROFILE} dry_run=${DRY_RUN} ========"

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
  fits=$(python3 -c "print(1 if $new_count <= $MAX_NODES and float('$new_ocpu') <= $MAX_OCPU and float('$new_mem') <= $MAX_MEM else 0)")
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
