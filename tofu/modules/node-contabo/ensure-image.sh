#!/usr/bin/env bash
# tofu/modules/node-contabo/ensure-image.sh
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

# Shared token cache + circuit breaker (per-account, per-runner).
# Parallel null_resource.ensure_image instances used to each call
# KeyCloak password-grant independently → brute-force lockout (~10 min).
# Cache path is keyed by a hash of the client id + username so multiple
# accounts on one runner don't share tokens. Circuit file is written on
# terminal 401 so siblings stop immediately instead of burning retries.
CONTABO_TOKEN_CACHE_DIR="${CONTABO_TOKEN_CACHE_DIR:-/tmp/contabo-token-cache}"
mkdir -p "$CONTABO_TOKEN_CACHE_DIR"
_auth_cache_key=$(printf '%s|%s' "${CONTABO_CLIENT_ID:-}" "${CONTABO_API_USER:-}" | sha256sum | awk '{print $1}')
TOKEN_CACHE_FILE="${CONTABO_TOKEN_CACHE_DIR}/${_auth_cache_key}.token"
TOKEN_LOCK_FILE="${CONTABO_TOKEN_CACHE_DIR}/${_auth_cache_key}.lock"
AUTH_CIRCUIT_FILE="${CONTABO_TOKEN_CACHE_DIR}/${_auth_cache_key}.circuit"
# Contabo access tokens are ~5 min; refresh after 240s.
TOKEN_MAX_AGE_SECS="${CONTABO_TOKEN_MAX_AGE_SECS:-240}"
# Circuit stays open for 11 min after a terminal 401 (KeyCloak lockout ~10m).
CIRCUIT_TTL_SECS="${CONTABO_AUTH_CIRCUIT_TTL_SECS:-660}"

_circuit_open() {
  [[ -f "$AUTH_CIRCUIT_FILE" ]] || return 1
  local age
  age=$(( $(date +%s) - $(stat -c %Y "$AUTH_CIRCUIT_FILE" 2>/dev/null || echo 0) ))
  if (( age < CIRCUIT_TTL_SECS )); then
    echo "Contabo auth circuit OPEN (${age}s/${CIRCUIT_TTL_SECS}s) — refusing password-grant to avoid extending KeyCloak lockout" >&2
    return 0
  fi
  rm -f "$AUTH_CIRCUIT_FILE"
  return 1
}

_trip_circuit() {
  echo "tripping Contabo auth circuit for ${CIRCUIT_TTL_SECS}s" >&2
  date -u +%Y-%m-%dT%H:%M:%SZ >"$AUTH_CIRCUIT_FILE"
}

# Auth — fail-fast on terminal HTTP statuses so retries don't extend
# KeyCloak's brute-force lockout. 5xx and network errors retry.
# Uses flock + file cache so concurrent provisioners share one token.
auth_token() {
  local resp tok attempt code body cached age

  if _circuit_open; then
    return 1
  fi

  if [[ -f "$TOKEN_CACHE_FILE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$TOKEN_CACHE_FILE" 2>/dev/null || echo 0) ))
    if (( age < TOKEN_MAX_AGE_SECS )); then
      cached=$(cat "$TOKEN_CACHE_FILE" 2>/dev/null || true)
      if [[ -n "$cached" ]]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi

  # Serialize refresh across parallel ensure-image processes.
  exec 9>"$TOKEN_LOCK_FILE"
  if ! flock -w 120 9; then
    echo "Contabo auth: could not acquire token lock" >&2
    return 1
  fi
  # Re-check cache after lock (another process may have refreshed).
  if [[ -f "$TOKEN_CACHE_FILE" ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$TOKEN_CACHE_FILE" 2>/dev/null || echo 0) ))
    if (( age < TOKEN_MAX_AGE_SECS )); then
      cached=$(cat "$TOKEN_CACHE_FILE" 2>/dev/null || true)
      if [[ -n "$cached" ]]; then
        printf '%s' "$cached"
        return 0
      fi
    fi
  fi

  for attempt in 1 2 3 4 5; do
    if _circuit_open; then
      return 1
    fi
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
      printf '%s' "$tok" >"$TOKEN_CACHE_FILE"
      chmod 600 "$TOKEN_CACHE_FILE" 2>/dev/null || true
      rm -f "$AUTH_CIRCUIT_FILE"
      printf '%s' "$tok"
      return 0
    fi
    if [[ "$code" == "400" || "$code" == "401" || "$code" == "403" ]]; then
      echo "Contabo auth: HTTP ${code} terminal. Body: ${body:0:300}" >&2
      _trip_circuit
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
  local token snap current status stagger

  # Stagger reinstalls across parallel provisioners so Contabo API +
  # KeyCloak aren't hit as a thundering herd. Deterministic per
  # INSTANCE_ID so re-runs of the same node keep the same offset.
  # Disabled when CONTABO_REINSTALL_STAGGER_SECS=0.
  if [[ "${FORCE_REINSTALL:-0}" == "1" || "${TARGET_IMAGE_ID:-}" != "" ]]; then
    stagger=${CONTABO_REINSTALL_STAGGER_SECS:-20}
    if (( stagger > 0 )); then
      local offset
      offset=$(( 0x$(printf '%s' "$INSTANCE_ID" | sha256sum | head -c 4) % (stagger + 1) ))
      if (( offset > 0 )); then
        echo "staggering reinstall path by ${offset}s (max ${stagger}s)"
        sleep "$offset"
      fi
    fi
  fi

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
