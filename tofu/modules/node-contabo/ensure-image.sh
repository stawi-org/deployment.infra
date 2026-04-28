#!/usr/bin/env bash
# tofu/modules/node-contabo/ensure-image.sh
#
# Two modes, controlled by $MODE:
#
#   verify    — First-create path. contabo_instance.this just POST'd
#               the target image to Contabo, which installed it on the
#               fresh disk. We just wait for Talos to answer on :50000
#               so downstream layers see a ready node. No reinstall,
#               no disk wipe.
#
#   reinstall — Operator bumped force_reinstall_generation. Issue a
#               full-payload PUT /v1/compute/instances/{id} (the proven
#               contabo.py shape: imageId + sshKeys + rootPassword +
#               defaultUser) — an image-only PUT is treated by Contabo
#               as a metadata update, not a disk wipe, so the payload
#               shape matters. Then wait for :50000 as above.
#
# Both modes end with a TCP probe to :50000 because that's the only
# reliable "Talos is actually running on the disk" signal. Contabo's
# own `status` / `imageId` API fields are set-only metadata.
#
# Env (set by null_resource.ensure_image in main.tf):
#   MODE                   — "verify" | "reinstall"
#   INSTANCE_ID            — Contabo instance numeric id
#   TARGET_IMAGE_ID        — desired imageId (UUID)
#   NODE_ROLE              — "controlplane" | "worker". Controls failure
#                            handling: worker failures log a warning and
#                            exit 0 so a single bad VPS doesn't block
#                            sibling provisioning; controlplane failures
#                            fail tofu (quorum matters).
#   CONTABO_CLIENT_ID/_SECRET/_API_USER/_API_PASSWORD — OAuth2 creds

set -euo pipefail

: "${MODE:?MODE must be 'verify' or 'reinstall'}"
: "${NODE_ROLE:?NODE_ROLE must be set (controlplane|worker)}"

# Log everything to a file so failures are diagnosable even when
# Terraform suppresses live stdout because env has sensitive values.
LOG="/tmp/ensure-image-${INSTANCE_ID:-unknown}-$$.log"
exec > >(tee -a "$LOG") 2>&1
echo "[ensure-image] mode=$MODE log=$LOG"
trap 'echo "[ensure-image] exit=$? log=$LOG"' EXIT

uuid() { cat /proc/sys/kernel/random/uuid; }

auth_token() {
  # Contabo's Keycloak token endpoint occasionally returns
  # invalid_grant for credentials that just authenticated seconds ago
  # (observed across three parallel null_resource.ensure_image
  # invocations in the same apply — 2/3 succeeded, 1/3 got
  # "invalid_grant"). Retry with short backoff.
  local resp tok attempt
  for attempt in 1 2 3 4 5; do
    resp=$(curl -sS -X POST 'https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "client_id=${CONTABO_CLIENT_ID}" \
      --data-urlencode "client_secret=${CONTABO_CLIENT_SECRET}" \
      --data-urlencode "username=${CONTABO_API_USER}" \
      --data-urlencode "password=${CONTABO_API_PASSWORD}" \
      --data-urlencode 'grant_type=password')
    tok=$(jq -r '.access_token // empty' <<<"$resp")
    if [[ -n "$tok" ]]; then
      printf '%s' "$tok"
      return 0
    fi
    echo "Contabo auth attempt $attempt failed. Body: $resp" >&2
    sleep $((attempt * 3))
  done
  echo "Contabo auth failed after 5 attempts" >&2
  return 1
}

api_get() {
  curl -sS \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "x-request-id: $(uuid)" \
    "$1"
}

# Wrap the provisioning body in a function so we can capture its exit
# code and apply per-role failure policy (workers warn-and-continue,
# controlplanes fail tofu). Use 'return' inside; never 'exit'.
do_provision() {
  TOKEN=$(auth_token)

  # Contabo's response shape: .data[0].ipConfig.v4 is an OBJECT with
  # .ip (not an array). Confirmed via contabo.py's own accessor.
  INSTANCE_IP=$(api_get "https://api.contabo.com/v1/compute/instances/${INSTANCE_ID}" \
    | jq -r '.data[0].ipConfig.v4.ip')
  if [[ -z "$INSTANCE_IP" || "$INSTANCE_IP" == "null" ]]; then
    echo "could not resolve IPv4 for instance ${INSTANCE_ID}" >&2
    return 1
  fi
  echo "instance=${INSTANCE_ID} ip=${INSTANCE_IP} target=${TARGET_IMAGE_ID}"

  port_open() {
    timeout 3 bash -c "echo >/dev/tcp/${INSTANCE_IP}/50000" 2>/dev/null
  }

  instance_snapshot() {
    api_get "https://api.contabo.com/v1/compute/instances/${INSTANCE_ID}"
  }

  if [[ "$MODE" == "reinstall" ]]; then
    PRE=$(instance_snapshot)
    PRE_STATUS=$(jq -r '.data[0].status' <<<"$PRE")
    PRE_IMAGE=$(jq -r '.data[0].imageId' <<<"$PRE")
    echo "pre-reinstall: status=${PRE_STATUS} imageId=${PRE_IMAGE}"

    # Full-payload PUT. Mirrors contabo.py reinstall_instance(). Observed:
    # without userData, the PUT is accepted with HTTP 200 but silently
    # ignored — no disk wipe, tofu state thinks the reinstall succeeded,
    # downstream talos_machine_configuration_apply + bootstrap then run
    # against the still-old disk. With a malformed userData (e.g. bare
    # "#talos"), Contabo rejects HTTP 400 "Invalid yaml format".
    # What works: a minimal valid cloud-config YAML document. Talos
    # itself ignores cloud-init entirely — the siderolink.api kernel arg
    # is baked into the boot image via the Image Factory schematic
    # (schematic.yaml.tftpl), not via userData.
    USER_DATA_JSON=$(jq -Rs '.' <<<$'#cloud-config\nusers: []\n')
    echo "issuing PUT /compute/instances/${INSTANCE_ID} with imageId=${TARGET_IMAGE_ID}"
    RESP=$(curl -sS -w $'\nHTTP_%{http_code}' -X PUT \
      -H "Authorization: Bearer ${TOKEN}" \
      -H "x-request-id: $(uuid)" \
      -H 'Content-Type: application/json' \
      "https://api.contabo.com/v1/compute/instances/${INSTANCE_ID}" \
      -d "{\"imageId\":\"${TARGET_IMAGE_ID}\",\"sshKeys\":[],\"rootPassword\":0,\"userData\":${USER_DATA_JSON},\"defaultUser\":\"root\"}")
    CODE=$(awk -F_ '/^HTTP_/{print $2; exit}' <<<"$RESP")
    BODY=$(awk '/^HTTP_/{exit} {print}' <<<"$RESP")
    echo "PUT response: HTTP=${CODE}"
    echo "PUT body: ${BODY}"
    if [[ "$CODE" -lt 200 || "$CODE" -ge 300 ]]; then
      echo "reinstall PUT returned non-2xx HTTP ${CODE}" >&2
      return 1
    fi

    # Authoritative signal that reinstall actually started: Contabo's
    # status field transitions running → provisioning → running. If the
    # instance never leaves "running", the PUT was accepted but no disk
    # wipe happened (a silent no-op we've observed). Fail loudly so the
    # apply surfaces it instead of proceeding on stale disk state.
    echo "waiting for Contabo status to leave 'running' (confirms reinstall started)"
    LEFT_RUNNING=false
    for i in $(seq 1 30); do  # up to 5 min
      SNAP=$(instance_snapshot)
      STATUS=$(jq -r '.data[0].status' <<<"$SNAP")
      echo "  attempt ${i}/30: contabo status=${STATUS}"
      if [[ "$STATUS" != "running" && "$STATUS" != "null" && -n "$STATUS" ]]; then
        LEFT_RUNNING=true
        break
      fi
      sleep 10
    done
    if [[ "$LEFT_RUNNING" != "true" ]]; then
      echo "Contabo reinstall PUT accepted but instance never left 'running' state." >&2
      echo "Disk was not actually re-imaged. Cannot proceed." >&2
      return 1
    fi

    # Then wait for it to return to running (reinstall finished on Contabo side).
    echo "waiting for Contabo status to return to 'running' (reinstall finishing)"
    BACK_RUNNING=false
    for i in $(seq 1 90); do  # up to 15 min
      SNAP=$(instance_snapshot)
      STATUS=$(jq -r '.data[0].status' <<<"$SNAP")
      IMG=$(jq -r '.data[0].imageId' <<<"$SNAP")
      echo "  attempt ${i}/90: contabo status=${STATUS} imageId=${IMG}"
      if [[ "$STATUS" == "running" ]]; then
        BACK_RUNNING=true
        break
      fi
      sleep 10
    done
    if [[ "$BACK_RUNNING" != "true" ]]; then
      echo "Contabo reinstall didn't return to 'running' within 15 minutes" >&2
      return 1
    fi
  fi

  # Wait for Talos API on :50000 — sole trustworthy "disk has correct
  # booted OS" signal. Works for both modes: verify (just-POSTed instance
  # finishing first boot) and reinstall (new Talos booting after wipe).
  # Matches wait_for_nodes_ready in contabo.py.
  echo "waiting for Talos API on ${INSTANCE_IP}:50000 (up to 20 min)"
  for i in $(seq 1 120); do
    if port_open; then
      echo "attempt ${i}/120: ${INSTANCE_IP}:50000 open — node ready"
      return 0
    fi
    echo "attempt ${i}/120: ${INSTANCE_IP}:50000 not open yet"
    sleep 10
  done
  echo "Talos API not reachable on ${INSTANCE_IP}:50000 after 20 min" >&2
  return 1
}

# Per-node failure isolation: a failed worker provision (bad VPS, stuck
# reinstall, transient API error) must NOT abort sibling node creates
# in the same apply. CP failures still fail tofu — they affect quorum.
if do_provision; then
  rc=0
else
  rc=$?
fi

if (( rc != 0 )) && [[ "$NODE_ROLE" == "worker" ]]; then
  echo "::warning::worker provision failed (rc=$rc) — continuing per worker-failure isolation policy" >&2
  exit 0
fi
exit $rc
