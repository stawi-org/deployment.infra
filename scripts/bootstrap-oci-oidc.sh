#!/usr/bin/env bash
# scripts/bootstrap-oci-oidc.sh
#
# Idempotently configure OCI Identity Domain for GitHub Actions OIDC workload
# identity federation, per Oracle's documented pattern:
#
#   GitHub JWT  →  Identity Propagation Trust (with rule)
#                       ↓ matched claim
#                  Service User (specific OCI principal)
#                       ↓ member of
#                  Group  ←— IAM policy (compute / network / bastion)
#                       ↑ exchange result
#                  UPST (short-lived OCI session token)
#                       ↓ consumed by
#                  terraform-provider-oci (via ~/.oci/config)
#
# Prereqs:
#   - oci CLI installed and authed (or run from OCI Cloud Shell — all deps
#     below are pre-installed there)
#   - jq, curl, python3
#
# Runs unchanged on OCI Cloud Shell. The `gh` CLI is NOT required here —
# the script prints an inventory-ready OCI account stanza to stdout.
#
# Multi-tenancy / multi-profile:
#   --profile <NAME>     OCI CLI profile from ~/.oci/config. Default "DEFAULT".
#   --gh-profile <NAME>  Profile name written to the OCI account key in
#                        the rendered inventory stanza. Defaults to a slugged
#                        form of --profile (lowercase alnum). Pick something
#                        short, e.g. "stawi", "acctB".
#   --suffix <N>         Inventory export label for the printed example block.
#                        Default "0".
#   --tenancy / --region / --compartment auto-detect from the profile when
#                        omitted (via `oci iam region get` and profile config).
#
# Usage (single tenancy):
#   ./scripts/bootstrap-oci-oidc.sh --profile DEFAULT --gh-profile stawi --suffix 0
#
# Usage (multi-tenancy — run once per profile):
#   ./scripts/bootstrap-oci-oidc.sh --profile tenantA --gh-profile stawi --suffix 0
#   ./scripts/bootstrap-oci-oidc.sh --profile tenantB --gh-profile acctB --suffix 1
#   ./scripts/bootstrap-oci-oidc.sh --profile tenantC --gh-profile acctC --suffix 2
#
# Each invocation prints an OCI account stanza that (when pasted) sets:
# tenancy_ocid, compartment_ocid, region, vcn_cidr, enable_ipv6, auth, labels,
# annotations, nodes.
#
# Re-running is safe. Every resource is looked up by name; missing ones are
# created, existing ones are updated.

set -euo pipefail

# -------- defaults --------
PROFILE="DEFAULT"
SUFFIX="0"
TENANCY_OCID=""
REGION=""
COMPARTMENT_OCID=""
GH_REPO="antinvestor/deployments"
GH_BRANCH="main"
# Budget guardrail. Tofu provisioning only uses Always-Free A1 compute (cost
# ~ $0), but a small budget gives early warning if anything paid creeps in.
BUDGET_AMOUNT="${BUDGET_AMOUNT:-10}"      # USD per month
# BUDGET_EMAIL: alert recipient. If unset, defaults to `git config user.email`
# of the operator running this script (the most common single-operator
# convention). Override with --budget-email or env BUDGET_EMAIL=...
# Fallback to empty (no alerts) only if neither is available.
BUDGET_EMAIL="${BUDGET_EMAIL:-$(git config --global --get user.email 2>/dev/null || git config --get user.email 2>/dev/null || true)}"
BUDGET_NAME="${BUDGET_NAME:-stawi-cluster-budget}"
# Tofu/workflow-facing profile name. Defaults to a slugged form of the local
# OCI CLI profile. It must match the key in the tofu oci_accounts map AND
# resolve to a valid filesystem name for the ~/.oci/config profile written
# by the workflow runner.
GH_PROFILE=""

APP_NAME="${APP_NAME:-github-actions-cluster}"
SERVICE_USER_NAME="${SERVICE_USER_NAME:-cluster-provisioner}"
GROUP_NAME="${GROUP_NAME:-cluster-provisioners}"
POLICY_NAME="${POLICY_NAME:-cluster-provisioners-policy}"
TRUST_NAME="${TRUST_NAME:-github-actions-antinvestor}"

usage() {
  sed -n '2,50p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --profile)        PROFILE="$2"; shift 2 ;;
    --gh-profile)     GH_PROFILE="$2"; shift 2 ;;
    --suffix)         SUFFIX="$2"; shift 2 ;;
    --tenancy)        TENANCY_OCID="$2"; shift 2 ;;
    --region)         REGION="$2"; shift 2 ;;
    --compartment)    COMPARTMENT_OCID="$2"; shift 2 ;;
    --repo)           GH_REPO="$2"; shift 2 ;;
    --branch)         GH_BRANCH="$2"; shift 2 ;;
    --budget-amount)  BUDGET_AMOUNT="$2"; shift 2 ;;
    --budget-email)   BUDGET_EMAIL="$2"; shift 2 ;;
    --budget-name)    BUDGET_NAME="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *)                echo "unknown arg: $1" >&2; usage ;;
  esac
done

for cmd in oci jq curl python3 ; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 2; }
done

say()  { printf '\e[1;34m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$PROFILE" "$*"; }
warn() { printf '\e[1;33m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$PROFILE" "$*" >&2; }
die()  { printf '\e[1;31m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$PROFILE" "$*" >&2; exit 1; }

# Default GH_PROFILE = slug of local PROFILE: lowercase, only a-z0-9, collapsed.
# e.g. "BWIRE@STAWI.ORG" → "bwirestawiorg". Override with --gh-profile.
if [[ -z "$GH_PROFILE" ]]; then
  GH_PROFILE=$(printf '%s' "$PROFILE" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
  [[ -z "$GH_PROFILE" ]] && GH_PROFILE="account${SUFFIX}"
fi
say "inventory account key: $GH_PROFILE"

# -------- auto-detect from profile --------
CONFIG_FILE="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"

autodetect_from_profile() {
  local key="$1"
  [[ -r "$CONFIG_FILE" ]] || return 1
  awk -v profile="$PROFILE" -v key="$key" '
    BEGIN { in_section=0 }
    /^\[/ {
      in_section = ( $0 == "[" profile "]" )
      next
    }
    in_section && $1 ~ "^"key"=" { sub("^"key"=",""); print; exit }
  ' "$CONFIG_FILE" | tr -d '[:space:]'
}

if [[ -z "$TENANCY_OCID" ]]; then
  TENANCY_OCID=$(autodetect_from_profile "tenancy" || true)
  [[ -n "$TENANCY_OCID" ]] && say "auto-detected tenancy: $TENANCY_OCID"
fi
if [[ -z "$REGION" ]]; then
  REGION=$(autodetect_from_profile "region" || true)
  [[ -n "$REGION" ]] && say "auto-detected region: $REGION"
fi

# If the profile has security_token_file, it's a session-token profile
# (created via `oci session authenticate`) and CLI calls need --auth security_token.
# Otherwise the default API-key auth applies.
SECURITY_TOKEN_FILE=$(autodetect_from_profile "security_token_file" || true)
OCI_CLI=(oci --profile "$PROFILE")
if [[ -n "$SECURITY_TOKEN_FILE" ]]; then
  say "profile uses session-token auth (security_token_file=$SECURITY_TOKEN_FILE)"
  OCI_CLI+=(--auth security_token)

  # Check that the session hasn't expired — validate via token file mtime OR
  # by invoking a harmless API call. If expired, prompt for refresh.
  if ! "${OCI_CLI[@]}" iam region list >/dev/null 2>&1 ; then
    warn "Session token appears expired. Refresh with:"
    warn "  oci session refresh --profile \"$PROFILE\""
    warn "  # or if that fails:"
    warn "  oci session authenticate --profile-name \"$PROFILE\" --region $REGION"
    die "Aborting until the session is valid."
  fi
fi
if [[ -z "$COMPARTMENT_OCID" ]]; then
  # Default to the root compartment (== tenancy)
  COMPARTMENT_OCID="$TENANCY_OCID"
  [[ -n "$COMPARTMENT_OCID" ]] && say "compartment default (root): $COMPARTMENT_OCID"
fi

: "${TENANCY_OCID:?--tenancy required (not found in profile $PROFILE of $CONFIG_FILE)}"
: "${REGION:?--region required (not found in profile $PROFILE of $CONFIG_FILE)}"
: "${COMPARTMENT_OCID:?--compartment required}"

# =========================================================================
# 1. IDENTITY DOMAIN DISCOVERY
# =========================================================================
say "Discovering Identity Domain"
DOMAIN_JSON=$("${OCI_CLI[@]}" iam domain list \
  --compartment-id "$TENANCY_OCID" \
  --lifecycle-state ACTIVE \
  --all --output json)

DOMAIN_OCID=$(jq -r '.data[] | select(."display-name"=="Default") | .id' <<<"$DOMAIN_JSON" | head -1)
[[ -z "$DOMAIN_OCID" || "$DOMAIN_OCID" == "null" ]] && DOMAIN_OCID=$(jq -r '.data[0].id' <<<"$DOMAIN_JSON")
[[ -z "$DOMAIN_OCID" || "$DOMAIN_OCID" == "null" ]] && die "No active Identity Domain found"

DOMAIN_NAME=$(jq -r --arg id "$DOMAIN_OCID" '.data[] | select(.id==$id) | ."display-name"' <<<"$DOMAIN_JSON")
[[ -z "$DOMAIN_NAME" || "$DOMAIN_NAME" == "null" ]] && DOMAIN_NAME="Default"
DOMAIN_URL=$(jq -r --arg id "$DOMAIN_OCID" '.data[] | select(.id==$id) | .url' <<<"$DOMAIN_JSON")
# Normalise the domain URL with Python's urllib — strips trailing slash,
# drops the default :443 port, enforces https scheme. gtrevorrow/oci-
# token-exchange-action validates via new URL(base + '/oauth2/v1/token')
# and rejects anything that produces an invalid URL (empty, unscoped port,
# missing scheme, etc.).
DOMAIN_BASE_URL=$(python3 - <<PY
from urllib.parse import urlparse
u = urlparse("$DOMAIN_URL")
scheme = u.scheme or "https"
host = u.hostname
port = u.port
if port in (None, 443):
    print(f"{scheme}://{host}")
else:
    print(f"{scheme}://{host}:{port}")
PY
)

say "  domain:  $DOMAIN_OCID"
say "  URL raw: $DOMAIN_URL"
say "  URL gh:  $DOMAIN_BASE_URL  (emitted as OCI_DOMAIN_BASE_URL_${SUFFIX})"

# For oci CLI calls we use the raw URL (with :443 if OCI returned it) — the
# SDK is happy either way. Only the GH secret needs the normalised form so
# gtrevorrow/oci-token-exchange-action's JS URL() parse succeeds.
ID_ENDPOINT=(--endpoint "$DOMAIN_URL")

# =========================================================================
# 2. SERVICE USER
# =========================================================================
say "Ensuring service user '$SERVICE_USER_NAME'"
# Service Users are regular /admin/v1/Users resources with the extension
# schema urn:...:extension:user:User and serviceUser: true set.
# The serviceUser flag is mutability: immutable — set only at creation.
# OCI rejects token exchange impersonation of non-service users with:
#   {"error":"unauthorized_client",
#    "error_description":"User requesting is not a service user."}
USER_EXT_SCHEMA="urn:ietf:params:scim:schemas:oracle:idcs:extension:user:User"
# Look up the existing user by name. List-filter via SCIM is reliable for
# discovery; flag detection is done in two passes (see below) so we never
# delete a user just because we couldn't parse its serviceUser flag.
USER_QUERY=$(printf '%s' "userName eq \"$SERVICE_USER_NAME\"" | jq -sRr @uri)
USER_LIST_RAW=$("${OCI_CLI[@]}" raw-request \
  --target-uri "${DOMAIN_URL}/admin/v1/Users?filter=${USER_QUERY}" \
  --http-method GET --output json 2>/dev/null || echo '{"data":{"Resources":[]}}')
USER_OCID=$(jq -r '(.data.Resources // .data.resources // [])[0].id // empty' <<<"$USER_LIST_RAW")

# Default-SAFE: assume the existing user is OK unless we have positive
# proof otherwise. Only flip to "definitely-not-svc" when JSON parsing
# clearly returns serviceUser=false.  Ambiguous / missing key = leave it.
USER_NEEDS_RECREATE="false"
if [[ -n "$USER_OCID" ]]; then
  # GET the specific user by OCID. Searching by ID returns the full record
  # without SCIM `attributes=` filtering — every field the API stores comes
  # back, so we can probe several possible key paths defensively.
  USER_GET_RAW=$("${OCI_CLI[@]}" raw-request \
    --target-uri "${DOMAIN_URL}/admin/v1/Users/${USER_OCID}" \
    --http-method GET --output json 2>/dev/null || echo '{"data":{}}')
  # Walk the entire response tree looking for any leaf key matching
  # serviceUser / service-user / Service-User regardless of where OCI CLI
  # buried it. Robust to the CLI's inconsistent key normalisation
  # (camelCase->kebab, schema-URN flattening, etc.). The walk picks the
  # first match anywhere in the tree.
  IS_SVC=$(jq -r '
    def walk(f): . as $in
      | if type == "object" then reduce keys[] as $k ({}; . + {($k): ($in[$k] | walk(f))}) | f
        elif type == "array" then map(walk(f)) | f
        else f end;
    [ .. | objects | to_entries[]?
        | select(.key | ascii_downcase | gsub("[^a-z]"; "") == "serviceuser")
        | .value
    ] | first // "unknown" | tostring
  ' <<<"$USER_GET_RAW")
  # Diagnostic: print which JSON path holds the flag (useful to harden the
  # JQ once we see the actual response shape from a live OCI tenancy).
  if [[ "$IS_SVC" != "true" && "$IS_SVC" != "false" ]]; then
    say "  serviceUser flag not found anywhere; dumping response keys for debug:"
    jq -r '[.. | objects | to_entries[]? | .key] | unique | .[]' <<<"$USER_GET_RAW" 2>/dev/null \
      | head -40 | sed 's/^/      key: /' >&2 || true
  fi

  if [[ "$IS_SVC" == "false" ]]; then
    USER_NEEDS_RECREATE="true"
  elif [[ "$IS_SVC" == "true" ]]; then
    say "  user is already a service user — keeping"
  else
    say "  serviceUser flag indeterminate from API response — assuming OK (no destructive action)"
  fi
fi

USER_RECREATED="false"
if [[ "$USER_NEEDS_RECREATE" == "true" ]]; then
  warn "  existing user '$SERVICE_USER_NAME' is NOT a service user (serviceUser=$IS_SVC)"
  warn "  Deleting and recreating — serviceUser flag is immutable."

  # OCI refuses to delete a user that's still referenced by a Group or
  # IdentityPropagationTrust. Detach from each before deleting the user.
  EXISTING_GROUP_JSON=$("${OCI_CLI[@]}" identity-domains groups list "${ID_ENDPOINT[@]}" \
    --filter "displayName eq \"$GROUP_NAME\"" --output json 2>/dev/null || echo '{"data":{"resources":[]}}')
  EXISTING_GROUP_OCID=$(jq -r '.data.resources[0].id // empty' <<<"$EXISTING_GROUP_JSON")
  if [[ -n "$EXISTING_GROUP_OCID" ]]; then
    # Group members, like trust impersonationServiceUsers, are
    # SCIM returned=request — omitted from default GET responses.
    if "${OCI_CLI[@]}" identity-domains group get "${ID_ENDPOINT[@]}" --group-id "$EXISTING_GROUP_OCID" \
        --attributes "members" --output json 2>/dev/null \
        | jq -e --arg u "$USER_OCID" '.data.members // [] | any(.value==$u)' >/dev/null; then
      say "  removing user from group '$GROUP_NAME'"
      "${OCI_CLI[@]}" identity-domains group patch "${ID_ENDPOINT[@]}" --group-id "$EXISTING_GROUP_OCID" \
        --schemas '["urn:ietf:params:scim:api:messages:2.0:PatchOp"]' \
        --operations "[{\"op\":\"remove\",\"path\":\"members[value eq \\\"$USER_OCID\\\"]\"}]" \
        >/dev/null
    fi
  fi

  EXISTING_TRUST_JSON=$("${OCI_CLI[@]}" identity-domains identity-propagation-trusts list "${ID_ENDPOINT[@]}" \
    --filter "name eq \"$TRUST_NAME\"" --output json 2>/dev/null || echo '{"data":{"resources":[]}}')
  EXISTING_TRUST_OCID=$(jq -r '.data.resources[0].id // empty' <<<"$EXISTING_TRUST_JSON")
  if [[ -n "$EXISTING_TRUST_OCID" ]]; then
    say "  deleting dependent trust '$TRUST_NAME' (will be recreated later)"
    "${OCI_CLI[@]}" identity-domains identity-propagation-trust delete "${ID_ENDPOINT[@]}" \
      --identity-propagation-trust-id "$EXISTING_TRUST_OCID" --force >/dev/null
  fi

  "${OCI_CLI[@]}" identity-domains user delete "${ID_ENDPOINT[@]}" \
    --user-id "$USER_OCID" --force >/dev/null
  USER_OCID=""
  USER_RECREATED="true"
fi

if [[ -z "$USER_OCID" ]]; then
  say "  creating as service user (via raw SCIM POST)"
  # OCI CLI --from-json silently drops the nested "serviceUser": true inside
  # the extension schema — probably normalises camelCase inner keys in a way
  # the API doesn't recognise. Bypass by POSTing directly to the SCIM API
  # endpoint, which preserves the JSON body verbatim.
  USER_PAYLOAD=$(cat <<JSON
{
  "schemas": [
    "urn:ietf:params:scim:schemas:core:2.0:User",
    "$USER_EXT_SCHEMA"
  ],
  "userName": "$SERVICE_USER_NAME",
  "name": {"familyName": "Provisioner", "givenName": "Cluster"},
  "emails": [{"primary": true, "type": "work", "value": "${SERVICE_USER_NAME}@noreply.example.com"}],
  "active": true,
  "$USER_EXT_SCHEMA": {"serviceUser": true}
}
JSON
)
  USER_CREATE_RESP=$("${OCI_CLI[@]}" raw-request \
    --target-uri "${DOMAIN_URL}/admin/v1/Users" \
    --http-method POST \
    --request-body "$USER_PAYLOAD" \
    --output json)
  USER_OCID=$(jq -r '.data.id // empty' <<<"$USER_CREATE_RESP")
  if [[ -z "$USER_OCID" ]]; then
    echo "$USER_CREATE_RESP" | head -c 800 >&2
    die "User creation failed — see response above."
  fi
fi
say "  user:    $USER_OCID  (service user)"

# =========================================================================
# 3. GROUP
# =========================================================================
say "Ensuring group '$GROUP_NAME'"
GROUP_JSON=$("${OCI_CLI[@]}" identity-domains groups list "${ID_ENDPOINT[@]}" \
  --filter "displayName eq \"$GROUP_NAME\"" --output json)
GROUP_OCID=$(jq -r '.data.resources[0].id // empty' <<<"$GROUP_JSON")

if [[ -z "$GROUP_OCID" ]]; then
  say "  creating"
  GROUP_OCID=$("${OCI_CLI[@]}" identity-domains group create "${ID_ENDPOINT[@]}" \
    --schemas '["urn:ietf:params:scim:schemas:core:2.0:Group"]' \
    --display-name "$GROUP_NAME" \
    --members "[{\"type\":\"User\",\"value\":\"$USER_OCID\"}]" \
    --output json | jq -r '.data.id')
else
  # SCIM marks Group.members as returned=request — default GETs omit it.
  # Without --attributes members the membership check ALWAYS sees length=0
  # and 'add' runs every time. Worse, repeated 'adds' via the high-level
  # CLI subcommand can silently no-op against IDCS, leaving the user
  # outside the group while the script reports success — which manifests
  # later as 404-NotAuthorizedOrNotFound on every CreateImage / CreateVcn.
  is_member() {
    "${OCI_CLI[@]}" identity-domains group get "${ID_ENDPOINT[@]}" --group-id "$GROUP_OCID" \
      --attributes "members" --output json 2>/dev/null \
      | jq -e --arg u "$USER_OCID" '.data.members // [] | any(.value==$u)' >/dev/null
  }
  if ! is_member; then
    say "  adding service user (group missing user; patching)"
    # Use raw-request so the JSON body reaches IDCS verbatim — the high-level
    # `group patch` subcommand has been observed to drop the operation
    # silently against some IDCS versions.
    PATCH_BODY=$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
  "Operations": [
    {"op":"add","path":"members","value":[{"type":"User","value":"$USER_OCID"}]}
  ]
}
JSON
)
    PATCH_RESP=$("${OCI_CLI[@]}" raw-request \
      --target-uri "${DOMAIN_URL}/admin/v1/Groups/${GROUP_OCID}" \
      --http-method PATCH --request-body "$PATCH_BODY" --output json 2>&1 || true)
    if ! is_member; then
      warn "  PATCH did not establish membership; raw response:"
      printf '%s\n' "$PATCH_RESP" | head -c 800 >&2
      die "Aborting — group membership PATCH silently failed."
    fi
    say "  ✓ user is now a member of $GROUP_NAME"
  else
    say "  ✓ user already a member of $GROUP_NAME"
  fi
fi
say "  group:   $GROUP_OCID"

# =========================================================================
# 4. IAM POLICY
# =========================================================================
say "Ensuring IAM policy '$POLICY_NAME'"
# Single 'manage all-resources' grant in the compartment — gives the
# service account full authority over everything tofu provisions
# (VCN, instances, images, volumes, bastion, etc.) without having to
# enumerate resource families and chase down 404-NotAuthorizedOrNotFound
# on each missing one. The blast radius is bounded by COMPARTMENT_OCID
# (typically the tenancy root for this project — that is intentional;
# the service account is the cluster's own provisioner).
# Tenancy-scoped reads cover tagging, compartment lookup, and budget
# observation which can't live inside a single compartment.
#
# ID-FORMAT NOTE: identity-domains (IDCS-backed) Groups have a SCIM
# resource id that is NOT a valid OCI policy principal. Policies written
# as `Allow group id <SCIM_ID>` compile and store but evaluate to an
# empty group → effective permissions = zero → every write returns
# 404-NotAuthorizedOrNotFound even though the policy "looks correct."
# The domain-qualified name form (`Allow group '<DOMAIN>'/'<GROUP>'`)
# is resolved by IAM via name lookup within the identity domain and
# avoids the ID problem entirely.
POLICY_STMTS=$(cat <<EOF
[
  "Allow group '${DOMAIN_NAME}'/'${GROUP_NAME}' to manage all-resources                in compartment id $COMPARTMENT_OCID",
  "Allow group '${DOMAIN_NAME}'/'${GROUP_NAME}' to use    tag-namespaces               in tenancy",
  "Allow group '${DOMAIN_NAME}'/'${GROUP_NAME}' to read   compartments                 in tenancy",
  "Allow group '${DOMAIN_NAME}'/'${GROUP_NAME}' to read   usage-budgets                in tenancy"
]
EOF
)
POLICY_JSON=$("${OCI_CLI[@]}" iam policy list \
  --compartment-id "$COMPARTMENT_OCID" --name "$POLICY_NAME" \
  --output json 2>/dev/null || echo '{"data":[]}')
POLICY_OCID=$(jq -r '.data[0].id // empty' <<<"$POLICY_JSON")

if [[ -z "$POLICY_OCID" ]]; then
  say "  creating"
  POLICY_OCID=$("${OCI_CLI[@]}" iam policy create \
    --compartment-id "$COMPARTMENT_OCID" \
    --name "$POLICY_NAME" \
    --description "Grants $GROUP_NAME network/compute/bastion management" \
    --statements "$POLICY_STMTS" \
    --output json | jq -r '.data.id')
else
  say "  updating"
  # OCI CLI requires --version-date alongside --statements when updating.
  # Setting version-date to today = effective from today. Capture the
  # full response so we can fail loudly if the update silently no-oped.
  upd_out=$("${OCI_CLI[@]}" iam policy update --policy-id "$POLICY_OCID" \
    --statements "$POLICY_STMTS" \
    --version-date "$(date -u +%Y-%m-%d)" \
    --force --output json 2>&1) || true
  if ! printf '%s' "$upd_out" | jq empty 2>/dev/null; then
    warn "  policy update returned non-JSON; raw response:"
    printf '%s\n' "$upd_out" | head -c 800 >&2
    die "Aborting — policy update failed."
  fi
fi
say "  policy:  $POLICY_OCID"

# Verify the policy NOW contains every statement we intended. OCI policy
# changes propagate within seconds for the policy itself, but the
# UPST-bearer's effective permissions can lag a minute or two.
POLICY_GET_JSON=$("${OCI_CLI[@]}" iam policy get --policy-id "$POLICY_OCID" --output json)
CURRENT_STMTS=$(printf '%s' "$POLICY_GET_JSON" | jq -r '.data.statements[]?')
say "  policy statements now in OCI:"
printf '%s\n' "$CURRENT_STMTS" | sed 's/^/      /'

# Verifier — confirm the broad grant landed. With a single 'manage
# all-resources' statement there's nothing to enumerate; we just check
# that the statement is present in the policy as-stored.
all_resources_cnt=$(printf '%s' "$POLICY_GET_JSON" | jq -r \
  '[.data.statements[]? | select(test("manage[[:space:]]+all-resources[[:space:]]+in[[:space:]]+compartment"; "i"))] | length' \
  2>/dev/null || echo 0)
if [[ "$all_resources_cnt" = "0" ]]; then
  warn "  policy is MISSING the 'manage all-resources in compartment' grant."
  warn "  the update API call may have rate-limited or silently dropped it."
  warn "  re-run the script; if it persists, inspect via OCI Console → Identity → Policies."
else
  say "  ✓ 'manage all-resources' grant in place"
fi

# =========================================================================
# 5. CONFIDENTIAL OAUTH APP
# =========================================================================
say "Ensuring confidential OAuth app '$APP_NAME'"
APP_JSON=$("${OCI_CLI[@]}" identity-domains apps list "${ID_ENDPOINT[@]}" \
  --filter "displayName eq \"$APP_NAME\"" --output json)
APP_OCID=$(jq -r '.data.resources[0].id // empty' <<<"$APP_JSON")

APP_PAYLOAD=$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:schemas:oracle:idcs:App"],
  "displayName": "$APP_NAME",
  "description": "Confidential OAuth client for GitHub Actions → OCI UPST exchange",
  "isOAuthClient": true,
  "clientType": "confidential",
  "active": true,
  "allowedGrants": [
    "client_credentials",
    "urn:ietf:params:oauth:grant-type:jwt-bearer"
  ],
  "allowedOperations": ["introspect", "onBehalfOfUser"],
  "trustScope": "Explicit",
  "basedOnTemplate": {
    "value": "CustomWebAppTemplateId"
  }
}
JSON
)

if [[ -z "$APP_OCID" ]]; then
  say "  creating"
  CREATE_OUT=$("${OCI_CLI[@]}" identity-domains app create "${ID_ENDPOINT[@]}" \
    --from-json "$APP_PAYLOAD" --output json 2>&1) || true
  APP_OCID=$(echo "$CREATE_OUT" | jq -r '.data.id // empty' 2>/dev/null || true)
  if [[ -z "$APP_OCID" ]]; then
    warn "CLI app creation failed. Error:"
    echo "$CREATE_OUT" | head -40 >&2
    warn "Create manually (Identity Domain → Applications → + Add application → Confidential), then re-run."
    exit 3
  fi
else
  # App already exists — skip the full `put` replacement. oci's `app put`
  # requires the complete resource schema (not just the fields we set on
  # create), so attempting a partial put prompts "Are you sure?" or fails
  # schema validation. The resource was fully configured on first create;
  # re-runs are no-ops for the app itself.
  say "  exists (no-op; delete manually + re-run to regenerate)"
fi

APP_DETAIL=$("${OCI_CLI[@]}" identity-domains app get "${ID_ENDPOINT[@]}" --app-id "$APP_OCID" --output json)
CLIENT_ID=$(jq -r '.data.name' <<<"$APP_DETAIL")
CLIENT_SECRET=$(jq -r '.data."client-secret" // empty' <<<"$APP_DETAIL")

if [[ -z "$CLIENT_SECRET" ]]; then
  warn "client_secret not returned by API (common after first-read)."
  warn "Regenerate via: Identity Domain → Applications → $APP_NAME → OAuth → Regenerate secret"
  read -r -p "Paste the client_secret (or press enter to skip GH secret push): " CLIENT_SECRET || true
fi

say "  app:     $APP_OCID"
say "  clientID: $CLIENT_ID"

# =========================================================================
# 6. IDENTITY PROPAGATION TRUST
# =========================================================================
say "Ensuring Identity Propagation Trust '$TRUST_NAME'"
# First look up by name (normal case)
TRUST_LIST=$("${OCI_CLI[@]}" identity-domains identity-propagation-trusts list "${ID_ENDPOINT[@]}" \
  --filter "name eq \"$TRUST_NAME\"" --output json 2>/dev/null || echo '{"data":{"resources":[]}}')
TRUST_OCID=$(jq -r '.data.resources[0].id // empty' <<<"$TRUST_LIST")

# Fall back to issuer match. OCI enforces issuer uniqueness, so a prior
# failed run may have left a trust with a different name but same issuer.
if [[ -z "$TRUST_OCID" ]]; then
  TRUST_ALL=$("${OCI_CLI[@]}" identity-domains identity-propagation-trusts list "${ID_ENDPOINT[@]}" \
    --all --output json 2>/dev/null || echo '{"data":{"resources":[]}}')
  EXISTING=$(jq -r --arg iss "https://token.actions.githubusercontent.com" \
    '.data.resources[]? | select(.issuer==$iss) | {id,name}' <<<"$TRUST_ALL" | head -c 2000)
  if [[ -n "$EXISTING" ]]; then
    TRUST_OCID=$(jq -r --arg iss "https://token.actions.githubusercontent.com" \
      '[.data.resources[]? | select(.issuer==$iss)][0].id // empty' <<<"$TRUST_ALL")
    EXISTING_NAME=$(jq -r --arg iss "https://token.actions.githubusercontent.com" \
      '[.data.resources[]? | select(.issuer==$iss)][0].name // empty' <<<"$TRUST_ALL")
    warn "Trust with GitHub issuer already exists under a different name: '$EXISTING_NAME' ($TRUST_OCID)"
    warn "Reusing it. If you need the impersonation rule updated, delete it in the UI:"
    warn "  Identity Domain → Security → Identity Propagation Trusts → $EXISTING_NAME → Delete"
    warn "  Then re-run this script."
  fi
fi

SUB_PATTERN="repo:${GH_REPO}:"

# OCI's impersonation rule DSL only reliably supports the forms documented
# by Oracle: `<claim> eq *` (universal) and `<claim> eq <prefix>*` (wildcard).
# We use the universal form here; the REAL security boundary for this
# federation is:
#
#   1. clientClaimValues=[<client_id>] on the trust — only tokens whose `aud`
#      equals our confidential OAuth app's client_id are accepted.
#   2. The client_secret (Basic-auth on the token exchange) is stored in
#      GH Actions secrets scoped to this repo — only workflows that can
#      read the secret can complete the exchange.
#   3. GitHub signs every JWT with its own JWKS, so tokens can't be forged.
#
# Narrowing the sub-claim further (e.g. `sub eq repo:owner/name:*`) adds
# minimal extra defence and has proven brittle across OCI rule-DSL
# variations. The universal form ("sub eq *") is Oracle's canonical example
# in the JWT-to-UPST guide.
RULE='sub eq *'

TRUST_PAYLOAD=$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:schemas:oracle:idcs:IdentityPropagationTrust"],
  "name": "$TRUST_NAME",
  "description": "Trusts GitHub Actions OIDC tokens from $GH_REPO",
  "issuer": "https://token.actions.githubusercontent.com",
  "publicKeyEndpoint": "https://token.actions.githubusercontent.com/.well-known/jwks",
  "type": "JWT",
  "subjectType": "User",
  "subjectClaimName": "sub",
  "subjectMappingAttribute": "userName",
  "clientClaimName": "aud",
  "clientClaimValues": ["$CLIENT_ID"],
  "oauthClients": ["$CLIENT_ID"],
  "active": true,
  "allowImpersonation": true,
  "impersonationServiceUsers": [
    {
      "rule": "$RULE",
      "value": "$USER_OCID"
    }
  ]
}
JSON
)

if [[ -n "$TRUST_OCID" ]]; then
  # Validate the existing trust has all the fields the token-exchange flow
  # requires (clientClaimName/clientClaimValues/subjectMappingAttribute) AND
  # that its impersonationServiceUsers[0].value still points at the CURRENT
  # service user OCID. Old runs of this script (before the user-detection
  # fix) sometimes deleted+recreated the user, leaving the trust pinned to
  # a stale OCID — which manifests at apply time as 404-NotAuthorizedOrNotFound.
  # If we find a broken or stale trust, delete + recreate so re-runs self-heal.
  # impersonationServiceUsers has SCIM "returned: request" so default GETs
  # omit it — must pass --attributes to inspect the stored value.
  TRUST_RAW=$("${OCI_CLI[@]}" raw-request \
    --target-uri "${DOMAIN_URL}/admin/v1/IdentityPropagationTrusts/${TRUST_OCID}?attributes=clientClaimName,clientClaimValues,subjectMappingAttribute,impersonationServiceUsers" \
    --http-method GET --output json 2>/dev/null || echo '{"data":{}}')

  has_field() {
    # Top-level normalised field present + non-empty.
    local target="$1"
    jq -r --arg t "$target" '
      .data | to_entries[]?
      | select(.key | ascii_downcase | gsub("[^a-z]"; "") == $t)
      | .value
    ' <<<"$TRUST_RAW" 2>/dev/null \
      | { read -r v && [[ -n "$v" && "$v" != "null" && "$v" != "[]" && "$v" != "{}" ]] && echo "true" || echo "false"; }
  }

  has_client_claim=$(has_field "clientclaimname")
  has_client_values=$(has_field "clientclaimvalues")
  has_subject_map=$(has_field "subjectmappingattribute")
  # Targeted: rule + value live ONLY inside impersonationServiceUsers[].
  # Any other "rule" / "value" in the doc is unrelated.
  rule_value=$(jq -r '
    (.data."impersonation-service-users" // .data.impersonationServiceUsers // [])
    | (.[0] // {}).rule // ""
  ' <<<"$TRUST_RAW" 2>/dev/null || echo "")
  trust_user_value=$(jq -r '
    (.data."impersonation-service-users" // .data.impersonationServiceUsers // [])
    | (.[0] // {}).value // ""
  ' <<<"$TRUST_RAW" 2>/dev/null || echo "")

  user_drifted="false"
  if [[ -n "$trust_user_value" && "$trust_user_value" != "$USER_OCID" ]]; then
    user_drifted="true"
  fi

  if [[ "$user_drifted" = "true" ]]; then
    warn "  Trust impersonation user is STALE (stored=$trust_user_value, current=$USER_OCID)"
    warn "  Deleting trust so it gets re-bound to the current service user."
    "${OCI_CLI[@]}" identity-domains identity-propagation-trust delete "${ID_ENDPOINT[@]}" \
      --identity-propagation-trust-id "$TRUST_OCID" --force >/dev/null
    TRUST_OCID=""
  elif [[ "${USER_RECREATED:-false}" = "true" ]]; then
    say "  user was recreated this run → trust's impersonation value is stale, forcing recreate"
    "${OCI_CLI[@]}" identity-domains identity-propagation-trust delete "${ID_ENDPOINT[@]}" \
      --identity-propagation-trust-id "$TRUST_OCID" --force >/dev/null
    TRUST_OCID=""
  elif [[ "$has_client_claim" = "true" && "$has_client_values" = "true" \
        && "$has_subject_map" = "true" && "$rule_value" = "sub eq *" ]]; then
    say "  trust schema looks complete, impersonation user matches ($trust_user_value) — keeping"
  elif [[ "$has_client_claim" != "true" || "$has_client_values" != "true" \
          || "$has_subject_map" != "true" || -z "$rule_value" ]]; then
    warn "  Trust missing required fields (client_claim=$has_client_claim values=$has_client_values subj_map=$has_subject_map rule='$rule_value')"
    warn "  Deleting so we can recreate with the complete payload."
    "${OCI_CLI[@]}" identity-domains identity-propagation-trust delete "${ID_ENDPOINT[@]}" \
      --identity-propagation-trust-id "$TRUST_OCID" --force >/dev/null
    TRUST_OCID=""
  else
    say "  trust fields all present, rule='$rule_value' (expected 'sub eq *') — keeping (override RECREATE_TRUST=1 to force)"
    if [[ "${RECREATE_TRUST:-0}" = "1" ]]; then
      warn "  RECREATE_TRUST=1 set — forcing trust recreation"
      "${OCI_CLI[@]}" identity-domains identity-propagation-trust delete "${ID_ENDPOINT[@]}" \
        --identity-propagation-trust-id "$TRUST_OCID" --force >/dev/null
      TRUST_OCID=""
    fi
  fi
fi

if [[ -z "$TRUST_OCID" ]]; then
  say "  creating"
  TRUST_OCID=$("${OCI_CLI[@]}" identity-domains identity-propagation-trust create "${ID_ENDPOINT[@]}" \
    --from-json "$TRUST_PAYLOAD" \
    --output json | jq -r '.data.id')
fi
say "  trust:   $TRUST_OCID"

# =========================================================================
# 7. EMIT INVENTORY STANZA
# =========================================================================
say ""
say "=========================================================="
say "OCI workload identity federation ready for profile [$PROFILE]."
say ""

inventory_yaml=$(cat <<EOF
oci:
  accounts:
    ${GH_PROFILE}:
      tenancy_ocid: ${TENANCY_OCID}
      compartment_ocid: ${COMPARTMENT_OCID}
      region: ${REGION}
      vcn_cidr: ${VCN_CIDR:-10.200.0.0/16}
      enable_ipv6: true
      auth:
        domain_base_url: ${DOMAIN_BASE_URL}
        oidc_client_identifier: "${CLIENT_ID}:${CLIENT_SECRET:-<PASTE_CLIENT_SECRET>}"
      labels:
        node.antinvestor.io/capacity-pool: ampere-a1
      annotations:
        node.antinvestor.io/account-owner: platform
      nodes:
        # Generic node naming — controlplane/worker distinction is the
        # role: + plane label below, not the name. Avoids renames-on-promotion.
        oci-${GH_PROFILE}-node-1:
          role: controlplane
          shape: VM.Standard.A1.Flex
          ocpus: 4
          memory_gb: 24
          labels:
            node.antinvestor.io/plane: control-plane
            node.antinvestor.io/role-cache: "true"
            node.antinvestor.io/role-database: "true"
            node.antinvestor.io/role-queue: "true"
            node.kubernetes.io/external-load-balancer: "true"
          annotations:
            node.antinvestor.io/operator-note: control-plane
EOF
)
say "Rendered OCI inventory stanza:"
printf '%s\n' "$inventory_yaml"

# =========================================================================
# 8. BUDGET + ALERT (cost guardrail)
# =========================================================================
# Budgets MUST be created in the root tenancy compartment regardless of the
# compartment they target. We target $COMPARTMENT_OCID (the cluster compt)
# so cost rolls up only from cluster resources, not the whole tenancy.
say ""
say "Ensuring budget '$BUDGET_NAME' (USD ${BUDGET_AMOUNT}/month, target compartment $COMPARTMENT_OCID)"
# List via raw-request — bypasses oci-cli version differences in the
# `budgets budget list` subcommand naming.
BUDGETS_ENDPOINT_LIST="https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets?compartmentId=${TENANCY_OCID}&displayName=${BUDGET_NAME}"
BUDGET_LIST=$("${OCI_CLI[@]}" raw-request \
  --target-uri "$BUDGETS_ENDPOINT_LIST" --http-method GET --output json 2>/dev/null || echo '{"data":[]}')
if ! printf '%s' "$BUDGET_LIST" | jq empty 2>/dev/null; then
  warn "  budget list returned non-JSON (api disabled in region?); treating as empty"
  BUDGET_LIST='{"data":[]}'
fi
BUDGET_OCID=$(jq -r '.data[0].id // empty' <<<"$BUDGET_LIST")

if [[ -z "$BUDGET_OCID" ]]; then
  say "  creating (via raw-request — older oci-cli versions lack the create subcommand)"
  BUDGETS_ENDPOINT="https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets"
  BUDGET_BODY=$(jq -n \
    --arg cid "$TENANCY_OCID" --arg name "$BUDGET_NAME" --arg desc "Cluster cost guardrail; tracks $COMPARTMENT_OCID" \
    --argjson amt "$BUDGET_AMOUNT" --arg target "$COMPARTMENT_OCID" '{
      compartmentId: $cid,
      displayName:   $name,
      description:   $desc,
      amount:        $amt,
      resetPeriod:   "MONTHLY",
      targetType:    "COMPARTMENT",
      targets:       [$target]
    }')
  budget_create_out=$("${OCI_CLI[@]}" raw-request \
    --target-uri "$BUDGETS_ENDPOINT" --http-method POST \
    --request-body "$BUDGET_BODY" --output json 2>&1) || true
  if printf '%s' "$budget_create_out" | jq empty 2>/dev/null; then
    BUDGET_OCID=$(printf '%s' "$budget_create_out" | jq -r '.data.id // empty')
  fi
  if [[ -z "$BUDGET_OCID" ]]; then
    warn "  budget create failed; raw response:"
    printf '%s\n' "$budget_create_out" | head -c 800 >&2
    warn ""
    warn "  required policy on the admin principal: Allow group <admin> to manage usage-budgets in tenancy"
  fi
else
  say "  exists ($BUDGET_OCID); updating amount via raw-request"
  UPD_BODY=$(jq -n --argjson amt "$BUDGET_AMOUNT" '{amount: $amt}')
  "${OCI_CLI[@]}" raw-request \
    --target-uri "https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets/${BUDGET_OCID}" \
    --http-method PUT --request-body "$UPD_BODY" --output json >/dev/null 2>&1 || \
    warn "  budget update returned non-zero (often ok — display-name immutable)"
fi
say "  budget:  $BUDGET_OCID"

# Alert rule: only created when an email recipient is supplied. OCI requires
# at least one recipient (or "messaging" topic) per alert rule.
if [[ -n "$BUDGET_OCID" && -n "$BUDGET_EMAIL" ]]; then
  for THRESHOLD in 50 80 100; do
    ALERT_NAME="alert-${THRESHOLD}pct"
    ALERT_LIST=$("${OCI_CLI[@]}" raw-request \
      --target-uri "https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets/${BUDGET_OCID}/alertRules?displayName=${ALERT_NAME}" \
      --http-method GET --output json 2>/dev/null || echo '{"data":[]}')
    if ! printf '%s' "$ALERT_LIST" | jq empty 2>/dev/null; then
      ALERT_LIST='{"data":[]}'
    fi
    ALERT_OCID=$(jq -r '.data[0].id // empty' <<<"$ALERT_LIST")
    if [[ -z "$ALERT_OCID" ]]; then
      say "  creating alert ${ALERT_NAME} → ${BUDGET_EMAIL}"
      ALERT_BODY=$(jq -n \
        --arg name "$ALERT_NAME" \
        --argjson th "$THRESHOLD" \
        --arg recip "$BUDGET_EMAIL" \
        --arg msg "Budget ${BUDGET_NAME} hit ${THRESHOLD}% of monthly cap (\$${BUDGET_AMOUNT})." '{
          displayName:   $name,
          type:          "ACTUAL",
          threshold:     $th,
          thresholdType: "PERCENTAGE",
          recipients:    $recip,
          message:       $msg
        }')
      "${OCI_CLI[@]}" raw-request \
        --target-uri "https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets/${BUDGET_OCID}/alertRules" \
        --http-method POST --request-body "$ALERT_BODY" --output json \
        >/dev/null 2>&1 || warn "    alert ${ALERT_NAME} create failed (recipient quota? mail config?)"
    else
      say "  alert ${ALERT_NAME} exists ($ALERT_OCID)"
    fi
  done
elif [[ -n "$BUDGET_OCID" ]]; then
  say "  alert rules skipped (no --budget-email supplied; budget tracking still active in OCI Console)"
fi

say ""
say "Impersonation rule:"
say "  sub sw \"$SUB_PATTERN\"  →  user $SERVICE_USER_NAME ($USER_OCID)"
say "                         →  group $GROUP_NAME ($GROUP_OCID)"
say "                         →  policy $POLICY_NAME ($POLICY_OCID)"
