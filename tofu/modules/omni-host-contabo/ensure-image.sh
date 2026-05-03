#!/usr/bin/env bash
# tofu/modules/omni-host-contabo/ensure-image.sh
#
# Single, simple decision: does this Contabo instance currently
# report imageId == TARGET_IMAGE_ID?
#   - Yes  → no-op, exit 0.
#   - No   → PUT /v1/compute/instances/<id> with the target imageId,
#            wait for status to leave + return to "running", exit 0.
#
# That's the whole flow. There is no reinstall-request file, no
# MODE flag, no readiness probe. Under Omni the cluster runtime
# (machine inventory, Talos health, role assignment) is verified
# entirely by Omni itself; tofu's only job is to make sure the disk
# is on the right image.
#
# Env (set by null_resource.ensure_image in main.tf):
#   INSTANCE_ID            — Contabo instance numeric id
#   TARGET_IMAGE_ID        — desired imageId (UUID), per inventory
#   NODE_ROLE              — "controlplane" | "worker". Worker
#                            failures are warn-and-continue so a
#                            single bad VPS doesn't block siblings.
#   USER_DATA              — optional cloud-init blob. If set, it's
#                            included in the reinstall PUT (used by
#                            omni-host to bring the omni stack up).
#                            Omitted = minimal `users: []` stub
#                            (Talos ignores cloud-init entirely;
#                            siderolink params come from the image).
#   CONTABO_CLIENT_ID/_SECRET/_API_USER/_API_PASSWORD — OAuth2 creds.

set -euo pipefail

: "${INSTANCE_ID:?INSTANCE_ID required}"
: "${TARGET_IMAGE_ID:?TARGET_IMAGE_ID required}"
: "${NODE_ROLE:?NODE_ROLE must be set (controlplane|worker)}"

LOG="/tmp/ensure-image-${INSTANCE_ID}-$$.log"
exec > >(tee -a "$LOG") 2>&1
trap 'echo "[ensure-image] exit=$? log=$LOG"' EXIT
echo "[ensure-image] instance=${INSTANCE_ID} target=${TARGET_IMAGE_ID} role=${NODE_ROLE}"

uuid() { cat /proc/sys/kernel/random/uuid; }

# Auth — fail-fast on terminal HTTP statuses so retries don't extend
# KeyCloak's brute-force lockout. 5xx and network errors retry.
auth_token() {
  local resp tok attempt code body
  for attempt in 1 2 3 4 5; do
    resp=$(curl -sS -w $'\nHTTP_%{http_code}' -X POST 'https://auth.contabo.com/auth/realms/contabo/protocol/openid-connect/token' \
      -H 'Content-Type: application/x-www-form-urlencoded' \
      --data-urlencode "client_id=${CONTABO_CLIENT_ID}" \
      --data-urlencode "client_secret=${CONTABO_CLIENT_SECRET}" \
      --data-urlencode "username=${CONTABO_API_USER}" \
      --data-urlencode "password=${CONTABO_API_PASSWORD}" \
      --data-urlencode 'grant_type=password' 2>/dev/null) || true
    code=$(awk -F_ '/^HTTP_/{print $2; exit}' <<<"$resp")
    body=$(awk '/^HTTP_/{exit} {print}' <<<"$resp")
    tok=$(jq -r '.access_token // empty' <<<"$body" 2>/dev/null || true)
    if [[ -n "$tok" ]]; then
      printf '%s' "$tok"
      return 0
    fi
    if [[ "$code" == "400" || "$code" == "401" || "$code" == "403" ]]; then
      echo "Contabo auth: HTTP ${code} terminal. Body: ${body:0:300}" >&2
      return 1
    fi
    echo "Contabo auth attempt ${attempt}/5: HTTP ${code:-error}" >&2
    sleep $((attempt * 3))
  done
  return 1
}

api_get() {
  local token=$1 url=$2
  curl -sS -X GET "$url" \
    -H "Authorization: Bearer $token" \
    -H "x-request-id: $(uuid)"
}

api_put() {
  local token=$1 url=$2 body=$3
  curl -sS -X PUT "$url" \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    -H "x-request-id: $(uuid)" \
    -d "$body"
}

main() {
  local token snap current status
  token=$(auth_token)
  snap=$(api_get "$token" "https://api.contabo.com/v1/compute/instances/${INSTANCE_ID}")
  current=$(jq -r '.data[0].imageId // empty' <<<"$snap")
  status=$(jq -r '.data[0].status  // empty' <<<"$snap")
  echo "current imageId=${current} status=${status}"

  if [[ "$current" == "$TARGET_IMAGE_ID" ]]; then
    if [[ "${FORCE_REINSTALL:-0}" == "1" ]]; then
      echo "current imageId matches target, but FORCE_REINSTALL=1 — proceeding with PUT"
    else
      echo "already on target image — no-op"
      return 0
    fi
  fi

  # Reinstall PUT — full payload mirrors contabo.py reinstall_instance().
  # Image-only payloads are silently no-op'd by Contabo (HTTP 200, disk
  # untouched). Including userData + sshKeys + defaultUser forces the
  # disk-wipe path. Talos ignores cloud-init; the siderolink kernel arg
  # comes from the image itself.
  #
  # The default user_data MUST contain real newlines — Contabo's PUT
  # validates the field as YAML and rejects single-line input with
  # `{"message":["Invalid yaml format"],"statusCode":400}`. Bash's
  # default-substitution `${var:-...}` is parsed inside a regular
  # double-quoted context that doesn't interpret `\n`, so the literal
  # default has to contain actual line breaks (ANSI-C quoting).
  local default_ud
  default_ud=$'#cloud-config\nusers: []\n'
  local body
  body=$(jq -n --arg img "$TARGET_IMAGE_ID" \
                --arg ud "${USER_DATA:-$default_ud}" \
    '{imageId:$img, userData:$ud, sshKeys:[], defaultUser:"root"}')

  echo "issuing PUT with imageId=${TARGET_IMAGE_ID}"
  local resp
  resp=$(api_put "$token" "https://api.contabo.com/v1/compute/instances/${INSTANCE_ID}" "$body")
  echo "PUT response: $(jq -c '.' <<<"$resp" || echo "$resp")"

  # Wait for status to LEAVE running (confirms wipe started) then
  # RETURN to running (wipe complete). 5min + 15min ceilings.
  echo "waiting for status to leave running (reinstall starts)"
  local i
  for i in $(seq 1 30); do
    snap=$(api_get "$token" "https://api.contabo.com/v1/compute/instances/${INSTANCE_ID}")
    status=$(jq -r '.data[0].status' <<<"$snap")
    [[ "$status" != "running" && -n "$status" && "$status" != "null" ]] && break
    sleep 10
  done
  if [[ "$status" == "running" ]]; then
    echo "instance never left running — Contabo silently no-op'd the PUT" >&2
    return 1
  fi
  echo "left running (status=${status}); waiting for return"
  for i in $(seq 1 90); do
    snap=$(api_get "$token" "https://api.contabo.com/v1/compute/instances/${INSTANCE_ID}")
    status=$(jq -r '.data[0].status' <<<"$snap")
    current=$(jq -r '.data[0].imageId' <<<"$snap")
    echo "  attempt ${i}/90: status=${status} imageId=${current}"
    if [[ "$status" == "running" ]]; then
      echo "back to running on imageId=${current}"
      return 0
    fi
    sleep 10
  done
  echo "did not return to running within 15 min" >&2
  return 1
}

# Per-node failure isolation. Worker failures warn + exit 0 so a
# single bad VPS doesn't block sibling node creates in the same
# apply. CP failures fail tofu — quorum matters.
if main; then
  exit 0
fi

if [[ "$NODE_ROLE" == "worker" ]]; then
  echo "::warning::worker ${INSTANCE_ID} failed but continuing per worker-isolation policy"
  exit 0
fi
exit 1
