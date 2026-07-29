#!/usr/bin/env bats

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export INVENTORY_ROOT="$BATS_TEST_TMPDIR/inventory"

  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"
  cat >"$FAKE_BIN/oci-list" <<'FAKE'
#!/usr/bin/env bash
echo '{"data":[{"id":"ocid1.instance.oc1..abc","display-name":"oci-acct-node-1","shape":"VM.Standard.A1.Flex","region":"eu-frankfurt-1"}]}'
FAKE
  chmod +x "$FAKE_BIN/oci-list"
}

@test "seed writes nodes.yaml and state.yaml per OCI account" {
  run scripts/seed-inventory.sh \
    --dry-run \
    --output-dir "$INVENTORY_ROOT" \
    --oci-account acct \
    --oci-node oci-acct-node-1 \
    --oci-list-cmd oci-list

  [ "$status" -eq 0 ]
  [ -f "$INVENTORY_ROOT/oracle/acct/nodes.yaml" ]
  [ -f "$INVENTORY_ROOT/oracle/acct/state.yaml" ]
  grep -q "oci_instance_ocid: ocid1.instance.oc1..abc" "$INVENTORY_ROOT/oracle/acct/state.yaml"
}

@test "seed is idempotent on re-run" {
  scripts/seed-inventory.sh --dry-run \
    --output-dir "$INVENTORY_ROOT" \
    --oci-account acct --oci-node oci-acct-node-1 \
    --oci-list-cmd oci-list
  before=$(sha256sum "$INVENTORY_ROOT/oracle/acct/state.yaml" | awk '{print $1}')
  scripts/seed-inventory.sh --dry-run \
    --output-dir "$INVENTORY_ROOT" \
    --oci-account acct --oci-node oci-acct-node-1 \
    --oci-list-cmd oci-list
  after=$(sha256sum "$INVENTORY_ROOT/oracle/acct/state.yaml" | awk '{print $1}')
  [ "$before" = "$after" ]
}
