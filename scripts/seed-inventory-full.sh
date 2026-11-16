#!/usr/bin/env bash
# Full inventory seeding script for all accounts
# Usage: ./seed-inventory-full.sh [--dry-run]
# Requires: R2_ENDPOINT_URL, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY env vars

set -euo pipefail

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

: "${R2_ENDPOINT_URL:?R2_ENDPOINT_URL required}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID required}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY required}"

TMPDIR=$(mktemp -d)
echo "Working in $TMPDIR"

# Load oracle accounts from accounts.yaml
ACCOUNTS=$(yq -r '.oracle[]' tofu/shared/accounts.yaml)

for acct in $ACCOUNTS; do
  echo "Seeding inventory for oracle/$acct..."
  mkdir -p "$TMPDIR/oracle/$acct"
  
  # Create nodes.yaml with 1 CP only per account (A1 Flex, Always Free: 2 OCPU, 12 GB max)
  cat > "$TMPDIR/oracle/$acct/nodes.yaml" <<EOF
annotations:
  node.stawi.org/account-owner: "platform"
labels:
  node.stawi.org/account: "$acct"
nodes:
  oci-$acct-cp-1:
    annotations: {}
    labels:
      node.stawi.org/capacity-class: "always-free"
      node.stawi.org/plane: "controlplane"
      node.stawi.org/role-database: "false"
    boot_volume_size_gb: 196
    ocpus: 2
    memory_gb: 12
    provider_data: {}
    role: controlplane
    shape: VM.Standard.A1.Flex
    zone: ""
EOF
  
  # Create empty state.yaml
  cat > "$TMPDIR/oracle/$acct/state.yaml" <<EOF
provider_data: {}
EOF
done

# On-prem: a single physical server (tindase) with a GeForce RTX.
# Control planes live on OCI, so this box joins as a worker. It is a
# pure declaration — layer 02-onprem-infra provisions nothing; you
# install the Talos ISO yourself (see docs/onprem-gpu-node.md).
echo "Seeding inventory for onprem/tindase..."
mkdir -p "$TMPDIR/onprem/tindase"
cat > "$TMPDIR/onprem/tindase/nodes.yaml" <<EOF
annotations:
  node.stawi.org/account-owner: "platform"
labels:
  node.stawi.org/account: "tindase"
nodes:
  onprem-tindase-worker-1:
    annotations:
      node.stawi.org/operator-note: "physical server with NVIDIA GeForce RTX; Talos ISO carries the NVIDIA extensions (see docs/onprem-gpu-node.md)"
    labels:
      node.stawi.org/plane: "worker"
      node.stawi.org/role-database: "false"
    boot_volume_size_gb: 0
    ocpus: 8
    memory_gb: 32
    provider_data: {}
    role: worker
    shape: baremetal
    zone: ""
EOF

cat > "$TMPDIR/onprem/tindase/state.yaml" <<EOF
provider_data: {}
EOF

# GCP: the project is kept for the Omni host + WIF (omni_host_provider=gcp),
# but the default Spot worker pack is NOT wanted — Spot e2-standard-2 VMs are
# billed continuously and would put the cluster outside the "costs nothing"
# budget. Disable them explicitly so an empty nodes map does not re-seed the
# default pack. See tofu/modules/gcp-account-infra/defaults.tf.
for acct in $(yq -r '.gcp[]' tofu/shared/accounts.yaml); do
  echo "Seeding inventory for gcp/$acct (workers disabled)..."
  mkdir -p "$TMPDIR/gcp/$acct"
  cat > "$TMPDIR/gcp/$acct/nodes.yaml" <<EOF
annotations:
  node.stawi.org/account-owner: "platform"
  node.stawi.org/workers-enabled: "false"
labels:
  node.stawi.org/account: "$acct"
nodes: {}
EOF

  cat > "$TMPDIR/gcp/$acct/state.yaml" <<EOF
provider_data: {}
EOF
done

if [[ "${1:-}" == "--dry-run" ]]; then
  echo "=== DRY RUN - would upload to R2 ==="
  find "$TMPDIR" -type f -name "*.yaml" | while read f; do
    echo "--- $f ---"
    cat "$f"
  done
else
  echo "Syncing to R2..."
  aws s3 sync "$TMPDIR" "s3://cluster-tofu-state/production/inventory/" \
    --endpoint-url "$R2_ENDPOINT_URL" \
    --region us-east-1
  echo "Done!"
fi

# Cleanup
rm -rf "$TMPDIR"