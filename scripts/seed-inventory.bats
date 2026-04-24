#!/usr/bin/env bats

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export INVENTORY_ROOT="$BATS_TEST_TMPDIR/inventory"
  export BOOTSTRAP_FILE="$BATS_TEST_TMPDIR/bootstrap.yaml"

  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"
  cat >"$FAKE_BIN/contabo-list" <<'FAKE'
#!/usr/bin/env bash
echo '{"instances":[{"instanceId":99,"displayName":"already-here","ipConfig":{"v4":[{"ip":"1.2.3.4"}],"v6":[{"ip":"2a02::1"}]}}]}'
FAKE
  chmod +x "$FAKE_BIN/contabo-list"

  cat >"$BOOTSTRAP_FILE" <<'YAML'
contabo:
  acct:
    missing-node:
      contabo_instance_id: "42"
YAML
}

@test "seed writes nodes.yaml and state.yaml per account" {
  run scripts/seed-inventory.sh \
    --dry-run \
    --output-dir "$INVENTORY_ROOT" \
    --bootstrap "$BOOTSTRAP_FILE" \
    --contabo-account acct \
    --contabo-node already-here \
    --contabo-node missing-node \
    --contabo-list-cmd contabo-list

  [ "$status" -eq 0 ]
  [ -f "$INVENTORY_ROOT/contabo/acct/nodes.yaml" ]
  [ -f "$INVENTORY_ROOT/contabo/acct/state.yaml" ]
  grep -q "contabo_instance_id: '99'" "$INVENTORY_ROOT/contabo/acct/state.yaml"
  grep -q "contabo_instance_id: '42'" "$INVENTORY_ROOT/contabo/acct/state.yaml"
}

@test "seed is idempotent on re-run" {
  scripts/seed-inventory.sh --dry-run \
    --output-dir "$INVENTORY_ROOT" --bootstrap "$BOOTSTRAP_FILE" \
    --contabo-account acct --contabo-node already-here \
    --contabo-list-cmd contabo-list
  before=$(sha256sum "$INVENTORY_ROOT/contabo/acct/state.yaml" | awk '{print $1}')
  scripts/seed-inventory.sh --dry-run \
    --output-dir "$INVENTORY_ROOT" --bootstrap "$BOOTSTRAP_FILE" \
    --contabo-account acct --contabo-node already-here \
    --contabo-list-cmd contabo-list
  after=$(sha256sum "$INVENTORY_ROOT/contabo/acct/state.yaml" | awk '{print $1}')
  [ "$before" = "$after" ]
}
