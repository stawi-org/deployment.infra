#!/usr/bin/env bats
# Tests for scripts/talos-upgrade.sh

setup() {
  export BATS_TEST_TMPDIR="${BATS_TEST_TMPDIR:-$(mktemp -d)}"
  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"

  cat >"$FAKE_BIN/talosctl" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
  --talosconfig) shift 2 ; "$0" "$@" ;;
  upgrade)       echo "upgrade called: $*" ; exit 0 ;;
  version)       echo "Server:" ; echo "  Tag: $TALOS_FAKE_VERSION" ;;
  *)             echo "unexpected talosctl arg: $*" >&2 ; exit 2 ;;
esac
FAKE
  chmod +x "$FAKE_BIN/talosctl"

  # No-op sleep so the version-mismatch poll loop exits quickly in tests.
  printf '#!/usr/bin/env bash\nexit 0\n' >"$FAKE_BIN/sleep"
  chmod +x "$FAKE_BIN/sleep"
}

@test "errors when required env vars are missing" {
  run scripts/talos-upgrade.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"NODE"* ]]
}

@test "runs talosctl upgrade with --preserve" {
  export NODE=10.0.0.1
  export TALOSCONFIG=/dev/null
  export IMAGE=factory.talos.dev/installer/abc:v1.12.6
  export TALOS_FAKE_VERSION=v1.12.6
  run scripts/talos-upgrade.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"upgrade called"* ]]
  [[ "$output" == *"--preserve"* ]]
  [[ "$output" == *"--image=factory.talos.dev/installer/abc:v1.12.6"* ]]
  [[ "$output" == *"--nodes=10.0.0.1"* ]]
}

@test "fails when post-upgrade version does not match" {
  export NODE=10.0.0.1
  export TALOSCONFIG=/dev/null
  export IMAGE=factory.talos.dev/installer/abc:v1.12.6
  export TALOS_FAKE_VERSION=v1.12.5
  export EXPECT_VERSION=v1.12.6
  run scripts/talos-upgrade.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"version mismatch"* ]]
}
