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
#   - oci CLI installed and authed (or run from OCI Cloud Shell — most deps
#     below are pre-installed there)
#   - jq, curl, python3, git  (no gh CLI required)
#   - sops: latest release auto-installed/upgraded into ~/.local/bin
#     (override with SOPS_VERSION=vX.Y.Z)
#   - PATH auto-includes $HOME/.local/bin
#   - deployment.infra checkout (auto-detected, --repo-path, or cloned)
#   - GITHUB_TOKEN or GH_TOKEN (required for all git + PR steps). Fine-grained
#     PAT on stawi-org/deployment.infra: Contents R/W + Pull requests R/W.
#     Classic: repo scope. Clone/fetch/push are fully non-interactive (token
#     via Authorization header — no username/password prompts).
#
# Each invocation:
#   1. Configures the OCI Identity Domain (service user, group, policy,
#      OAuth app, identity propagation trust, monthly budget) idempotently.
#   2. Checks out origin/<base> into an isolated git worktree, writes a
#      SOPS-encrypted auth.yaml under tofu/shared/accounts/oracle/<gh-profile>/,
#      and adds the account under oracle: in tofu/shared/accounts.yaml.
#   3. Commits, pushes branch onboard-oracle-<gh-profile> (or --branch),
#      and opens a PR via the GitHub REST API (curl + token) unless
#      --no-push / --no-pr.
#   4. After the PR merges, workflow onboard-oracle.yml seeds free-tier
#      nodes.yaml in R2 and runs cluster-provision (images → tofu-apply →
#      cluster template) so the new tenancy expands the cluster.
#
# Isolation / stability:
#   - Repo writes touch only oracle/<gh-profile>/auth.yaml + one accounts.yaml
#     list entry. Other accounts are never rewritten.
#   - Existing sops auth.yaml is not regenerated unless values actually change
#     (or client_secret is supplied for a forced update).
#   - OCI budget is named per account (stawi-<gh-profile>-budget), amount
#     hard-capped at $2/month, and re-runs do not thrash the amount.
#
# Multi-tenancy / multi-profile:
#   --profile <NAME>     OCI CLI profile from ~/.oci/config. Default "DEFAULT".
#   --gh-profile <NAME>  Account key written to accounts.yaml + used in the
#                        encrypted auth.yaml path. Defaults to a slugged
#                        form of --profile (lowercase alnum).
#   --tenancy / --region / --compartment auto-detect from the profile when
#                        omitted.
#   --repo-path <PATH>   Path to the stawi-org/deployment.infra checkout.
#                        Defaults to `git rev-parse --show-toplevel` from cwd,
#                        else clones https://github.com/stawi-org/deployment.infra.git
#   --base-branch <NAME> Branch to open the PR against (default: main).
#   --branch <NAME>      Feature branch (default: onboard-oracle-<gh-profile>).
#   --no-push            Write + commit in the worktree only; skip push/PR.
#   --no-pr              Push the branch but do not open a PR (print compare URL).
#
# Usage:
#   export GITHUB_TOKEN=github_pat_...   # Contents + Pull requests on this repo
#   ./scripts/bootstrap-oci-oidc.sh --profile tenantA --gh-profile newaccount
#
# Re-running is safe. Every OCI resource is looked up by name; missing ones
# are created, existing ones are updated. The accounts.yaml edit is
# idempotent. The branch/PR are reused if they already exist.

set -euo pipefail

# Operator tools (sops, age, sometimes oci) are commonly installed under
# ~/.local/bin — especially on OCI Cloud Shell after a user-level install.
# Prepend it so the hard deps check finds them without requiring a manual
# export PATH=... before every run.
export PATH="${HOME}/.local/bin${PATH:+:$PATH}"

# -------- defaults --------
PROFILE="DEFAULT"
SUFFIX="0"
TENANCY_OCID=""
REGION=""
COMPARTMENT_OCID=""
# Only this repository is onboarded. Clone / PR / push always target it.
GH_REPO="stawi-org/deployment.infra"
DEFAULT_REPO_URL="https://github.com/${GH_REPO}.git"
GITHUB_API="https://api.github.com"
# Local checkout where the script writes the encrypted auth.yaml +
# accounts.yaml edit + opens a PR. Auto-detected via
# `git rev-parse --show-toplevel` from cwd when unset; otherwise cloned
# from DEFAULT_REPO_URL into a temp dir.
REPO_PATH=""
BASE_BRANCH="${BASE_BRANCH:-main}"
BRANCH=""
NO_PUSH="false"
NO_PR="false"
# Worktree used for the commit/push so the operator's current branch is
# left alone. Set during the write phase; cleaned up on exit when we
# created it.
ONBOARD_WORKTREE=""
ONBOARD_WORKTREE_CLEANUP="false"
# Budget guardrail. Always-Free A1 is ~$0; cap is a tripwire only.
# Hard ceiling: $2/month. Default $2. Never raise an existing budget above
# that; re-runs do not randomize or thrash amounts.
BUDGET_AMOUNT_MAX=2
BUDGET_AMOUNT="${BUDGET_AMOUNT:-$BUDGET_AMOUNT_MAX}"
# BUDGET_EMAIL: alert recipient. If unset, defaults to `git config user.email`
# of the operator running this script (the most common single-operator
# convention). Override with --budget-email or env BUDGET_EMAIL=...
# Fallback to empty (no alerts) only if neither is available.
BUDGET_EMAIL="${BUDGET_EMAIL:-$(git config --global --get user.email 2>/dev/null || git config --get user.email 2>/dev/null || true)}"
# Per-account budget name is set after GH_PROFILE is known (section 8) so
# onboarding one tenancy never mutates another account's budget object.
BUDGET_NAME="${BUDGET_NAME:-}"
# Tofu/workflow-facing profile name. Defaults to a slugged form of the local
# OCI CLI profile. It must match the key in the tofu oci_accounts map AND
# resolve to a valid filesystem name for the ~/.oci/config profile written
# by the workflow runner.
GH_PROFILE=""

APP_NAME="${APP_NAME:-github-actions-cluster}"
SERVICE_USER_NAME="${SERVICE_USER_NAME:-cluster-provisioner}"
GROUP_NAME="${GROUP_NAME:-cluster-provisioners}"
POLICY_NAME="${POLICY_NAME:-cluster-provisioners-policy}"
# Default trust name for this project. Issuer uniqueness still allows
# reusing an older trust created under a prior name (issuer match fallback).
TRUST_NAME="${TRUST_NAME:-github-actions-stawi}"

usage() {
  sed -n '2,60p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
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
    --repo-path)      REPO_PATH="$2"; shift 2 ;;
    --base-branch)    BASE_BRANCH="$2"; shift 2 ;;
    --branch)         BRANCH="$2"; shift 2 ;;
    --no-push)        NO_PUSH="true"; shift ;;
    --no-pr)          NO_PR="true"; shift ;;
    --budget-amount)  BUDGET_AMOUNT="$2"; shift 2 ;;
    --budget-email)   BUDGET_EMAIL="$2"; shift 2 ;;
    --budget-name)    BUDGET_NAME="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *)                echo "unknown arg: $1" >&2; usage ;;
  esac
done

say()  { printf '\e[1;34m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$PROFILE" "$*"; }
warn() { printf '\e[1;33m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$PROFILE" "$*" >&2; }
die()  { printf '\e[1;31m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$PROFILE" "$*" >&2; exit 1; }

# Ensure sops is on PATH at the latest GitHub release (or SOPS_VERSION if set).
# Installs/upgrades into ~/.local/bin. Needs curl (checked first).
# Fallback tag used only if the releases API is unreachable.
SOPS_VERSION_FALLBACK="v3.13.2"
ensure_sops() {
  command -v curl >/dev/null 2>&1 || die "missing: curl (needed to auto-install sops)"

  local want os arch asset dest tmp tag ver_line ver_num want_num

  # Resolve desired version: explicit SOPS_VERSION, else GitHub "latest".
  if [[ -n "${SOPS_VERSION:-}" ]]; then
    want="$SOPS_VERSION"
  else
    tag=$(curl -fsSL \
      -H 'Accept: application/vnd.github+json' \
      -H 'X-GitHub-Api-Version: 2022-11-28' \
      'https://api.github.com/repos/getsops/sops/releases/latest' 2>/dev/null \
      | jq -r '.tag_name // empty' 2>/dev/null || true)
    if [[ -n "$tag" && "$tag" != "null" ]]; then
      want="$tag"
    else
      want="$SOPS_VERSION_FALLBACK"
      warn "could not resolve latest sops release from GitHub; using fallback ${want}"
    fi
  fi
  # Normalize: accept "3.13.2" or "v3.13.2"
  [[ "$want" == v* ]] || want="v${want}"
  want_num="${want#v}"

  if command -v sops >/dev/null 2>&1; then
    # `sops --version` may print update chatter on stderr; take first version-like token.
    ver_line=$(sops --version 2>/dev/null | head -1 || true)
    ver_num=$(printf '%s' "$ver_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    if [[ -n "$ver_num" && "$ver_num" == "$want_num" ]]; then
      say "sops up to date: $(command -v sops) (v${ver_num})"
      return 0
    fi
    if [[ -n "$ver_num" ]]; then
      say "sops v${ver_num} on PATH — upgrading to ${want}"
    else
      say "sops present but version unreadable — installing ${want}"
    fi
  else
    say "sops not on PATH — installing ${want}"
  fi

  os=$(uname -s | tr '[:upper:]' '[:lower:]')
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported arch for sops auto-install: $arch (install sops manually)" ;;
  esac
  case "$os" in
    linux|darwin) ;;
    *) die "unsupported OS for sops auto-install: $os (install sops manually)" ;;
  esac

  asset="sops-${want}.${os}.${arch}"
  dest="${HOME}/.local/bin/sops"
  tmp=$(mktemp)
  mkdir -p "$(dirname "$dest")"
  if ! curl -fsSL -o "$tmp" \
      "https://github.com/getsops/sops/releases/download/${want}/${asset}"; then
    rm -f "$tmp"
    die "failed to download sops ${want} (${asset}) from GitHub releases"
  fi
  chmod +x "$tmp"
  mv "$tmp" "$dest"
  export PATH="${HOME}/.local/bin${PATH:+:$PATH}"
  command -v sops >/dev/null 2>&1 || die "sops installed to ${dest} but not found on PATH"
  # Prefer the copy we just installed when an older system sops shadows PATH.
  if [[ "$(command -v sops)" != "$dest" ]]; then
    export PATH="$(dirname "$dest"):$PATH"
  fi
  say "sops ready: $(command -v sops) ($(sops --version 2>/dev/null | head -1 | tr -d '\n'))"
}

for cmd in oci jq curl python3 git ; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 2; }
done
ensure_sops

# GitHub auth for this one repo. Prefer GITHUB_TOKEN; accept GH_TOKEN alias.
# Never print the token. Used for HTTPS git clone/fetch/push and REST PR create.
github_token() { printf '%s' "${GITHUB_TOKEN:-${GH_TOKEN:-}}"; }

github_require_token() {
  [[ -n "$(github_token)" ]] || die "GITHUB_TOKEN (or GH_TOKEN) is required for non-interactive git to ${GH_REPO}. Export a PAT with Contents R/W (+ Pull requests R/W to open PRs), then re-run."
}

# Run git against github.com using the token automatically — no username/password
# prompts. Uses HTTP Basic via http.extraheader (GitHub's supported PAT form)
# and disables credential helpers / terminal prompts that would otherwise ask.
# Origin remotes stay as the public HTTPS URL (token is never stored in config).
github_git() {
  local tok basic
  github_require_token
  tok=$(github_token)
  # base64 of "x-access-token:<pat>" — portable (openssl or base64).
  if command -v openssl >/dev/null 2>&1; then
    basic=$(printf 'x-access-token:%s' "$tok" | openssl base64 -A 2>/dev/null)
  fi
  if [[ -z "${basic:-}" ]]; then
    basic=$(printf 'x-access-token:%s' "$tok" | base64 | tr -d '\n')
  fi
  # GIT_TERMINAL_PROMPT=0: never fall back to interactive askpass.
  # credential.helper=: empty helper so OS keychain / store cannot override.
  GIT_TERMINAL_PROMPT=0 \
    git -c credential.helper= \
      -c "http.https://github.com/.extraheader=Authorization: Basic ${basic}" \
      "$@"
}

# Fetch one or more refs into refs/remotes/origin/* using the token.
# Usage: github_git_fetch "refs/heads/main:refs/remotes/origin/main" ...
github_git_fetch() {
  local ref
  github_require_token
  git -C "$REPO_PATH" remote set-url origin "$DEFAULT_REPO_URL" 2>/dev/null || true
  for ref in "$@"; do
    github_git -C "$REPO_PATH" fetch --quiet origin "+${ref}" \
      || return 1
  done
  return 0
}

github_git_clone() {
  local dest="$1"
  github_require_token
  github_git clone --branch "$BASE_BRANCH" --single-branch "$DEFAULT_REPO_URL" "$dest" \
    || die "git clone failed for ${GH_REPO} (check GITHUB_TOKEN scopes: Contents R/W on this repo)"
  # Ensure origin has no embedded credentials.
  git -C "$dest" remote set-url origin "$DEFAULT_REPO_URL"
}

# POST JSON body from stdin to GitHub REST. Prints response body.
# Sets _GITHUB_API_CODE. Returns 0 only for HTTP 2xx.
github_api_json() {
  local method="$1" path="$2"
  local tok body_file code
  tok=$(github_token)
  [[ -n "$tok" ]] || return 2
  body_file=$(mktemp)
  code=$(curl -sS -o "$body_file" -w '%{http_code}' \
    -X "$method" \
    -H "Authorization: Bearer ${tok}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    --data-binary @- \
    "${GITHUB_API}${path}")
  _GITHUB_API_CODE=$code
  cat "$body_file"
  rm -f "$body_file"
  [[ "$code" =~ ^2 ]]
}

# Find open PR URL for head branch → base, or empty.
github_find_open_pr() {
  local head="$1" base="$2" tok resp
  tok=$(github_token)
  [[ -n "$tok" ]] || return 0
  # head query is owner:branch; encode colon as %3A
  resp=$(curl -sS \
    -H "Authorization: Bearer ${tok}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${GITHUB_API}/repos/${GH_REPO}/pulls?state=open&base=${base}&head=stawi-org%3A${head}" \
    2>/dev/null) || return 0
  jq -r 'if type=="array" and length>0 then .[0].html_url else empty end' <<<"$resp" 2>/dev/null || true
}

# Create PR; print html_url on success.
github_create_pr() {
  local title="$1" head="$2" base="$3" body="$4" resp
  resp=$(jq -n \
    --arg title "$title" \
    --arg head "$head" \
    --arg base "$base" \
    --arg body "$body" \
    '{title:$title, head:$head, base:$base, body:$body}' \
    | github_api_json POST "/repos/${GH_REPO}/pulls") || {
    warn "GitHub PR create HTTP ${_GITHUB_API_CODE:-?} response: $(printf '%s' "$resp" | head -c 400)"
    return 1
  }
  jq -r '.html_url // empty' <<<"$resp"
}

cleanup_onboard_worktree() {
  if [[ "$ONBOARD_WORKTREE_CLEANUP" == "true" && -n "$ONBOARD_WORKTREE" && -d "$ONBOARD_WORKTREE" ]]; then
    git -C "$REPO_PATH" worktree remove --force "$ONBOARD_WORKTREE" 2>/dev/null || true
    rm -rf "$ONBOARD_WORKTREE" 2>/dev/null || true
  fi
}
trap cleanup_onboard_worktree EXIT

# Resolve the repo root before any OCI work. We fail fast here so a wrong
# path doesn't burn an entire OCI Identity Domain run before complaining.
if [[ -z "$REPO_PATH" ]]; then
  REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [[ -z "$REPO_PATH" ]]; then
  REPO_PATH="${TMPDIR:-/tmp}/deployment.infra-bootstrap-$$"
  say "no local checkout; cloning ${DEFAULT_REPO_URL} → $REPO_PATH (token auth, non-interactive)"
  github_git_clone "$REPO_PATH"
fi
REPO_PATH=$(cd "$REPO_PATH" && pwd)
[[ -f "$REPO_PATH/.sops.yaml" ]] \
  || die "$REPO_PATH has no .sops.yaml — wrong checkout? Aborting before any write."
# Refuse to write into a fork / unrelated clone.
origin_url=$(git -C "$REPO_PATH" config --get remote.origin.url 2>/dev/null || true)
case "$origin_url" in
  *stawi-org/deployment.infra*) ;;
  *)
    die "origin is '${origin_url:-unset}' — expected ${GH_REPO} (https://github.com/${GH_REPO}). Pass --repo-path to the correct clone."
    ;;
esac
# Normalize origin to public HTTPS (no credentials in config).
git -C "$REPO_PATH" remote set-url origin "$DEFAULT_REPO_URL" 2>/dev/null || true
github_require_token
say "GitHub auth: token present (non-interactive clone/fetch/push + PR API)"
say "repo path: $REPO_PATH ($GH_REPO, base: $BASE_BRANCH)"

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
fi

# Membership verification + self-heal. SCIM marks Group.members as
# returned=request — default GETs omit it. Without --attributes members
# the membership check ALWAYS sees length=0 and 'add' runs every time.
# Worse, both `group create --members` AND `group patch` via the high-
# level CLI subcommand have been observed to silently no-op against
# IDCS — IDCS accepts the request and returns success, but the
# membership doesn't actually persist. The user ends up outside the
# group while the script reports success, and every subsequent
# LaunchInstance / CreateImage / CreateVcn returns
# 404-NotAuthorizedOrNotFound. So we always verify post-create AND
# post-update; if missing, repair via raw SCIM PATCH (which reaches
# IDCS verbatim, sidestepping the high-level subcommand's drop bug).
is_member() {
  "${OCI_CLI[@]}" identity-domains group get "${ID_ENDPOINT[@]}" --group-id "$GROUP_OCID" \
    --attributes "members" --output json 2>/dev/null \
    | jq -e --arg u "$USER_OCID" '.data.members // [] | any(.value==$u)' >/dev/null
}

if ! is_member; then
  say "  adding service user (group missing user; patching via raw SCIM)"
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
    die "Aborting — group membership PATCH silently failed. Establish membership manually in OCI Console (Identity Domain → Groups → $GROUP_NAME → Users → +Add user → $SERVICE_USER_NAME) and re-run."
  fi
  say "  ✓ user is now a member of $GROUP_NAME"
else
  say "  ✓ user is a member of $GROUP_NAME"
fi
say "  group:   $GROUP_OCID"

# =========================================================================
# 3b. IDENTITY DOMAIN ADMINISTRATOR GRANT
# =========================================================================
# IAM policies (next section) cover the OCI control plane only — compute,
# networking, storage, IAM-classic. They do NOT cover IDCS operations
# (users, groups, OAuth apps, identity propagation trusts), which are
# governed by a SEPARATE authorization layer: Identity Domain AppRoles.
#
# Without this grant the WIF principal can manage everything tofu
# provisions but CAN'T self-heal its own group membership / re-run this
# script remotely from CI — every IDCS API call returns 401 Forbidden.
# Granting "Identity Domain Administrator" to the same group lets the
# WIF principal call /admin/v1/Groups, /admin/v1/Users, etc., enabling
# remote bootstrap repair without re-authenticating in OCI Cloud Shell.
#
# Privilege note: this is broad. The principal can now create/delete
# IDCS users, modify groups, modify the trust that authenticates itself,
# and modify policies. Use a narrower role ("User Administrator",
# "Application Administrator", or a custom AppRole) if you want a
# tighter blast radius — but you'll trade fewer self-heal scenarios
# for more operator interventions.
say "Ensuring '$GROUP_NAME' is granted Identity Domain Administrator"

# Find the Administrator AppRole by display name. AppRoles are scoped
# to a parent app (the Identity Domain admin app — its display name
# varies across tenancies, so we filter on the role name instead).
APPROLE_QUERY=$(printf '%s' "displayName eq \"Identity Domain Administrator\"" | jq -sRr @uri)
APPROLE_LIST=$("${OCI_CLI[@]}" raw-request \
  --target-uri "${DOMAIN_URL}/admin/v1/AppRoles?filter=${APPROLE_QUERY}" \
  --http-method GET --output json 2>/dev/null || echo '{"data":{"Resources":[]}}')
ADMIN_ROLE_OCID=$(jq -r '
  (.data.Resources // .data.resources // [])[0].id // empty
' <<<"$APPROLE_LIST")
ADMIN_APP_OCID=$(jq -r '
  (.data.Resources // .data.resources // [])[0].app.value // empty
' <<<"$APPROLE_LIST")

if [[ -z "$ADMIN_ROLE_OCID" || -z "$ADMIN_APP_OCID" ]]; then
  warn "  Could not find 'Identity Domain Administrator' AppRole."
  warn "  Skipping the grant. Self-heal from CI won't work; re-run this"
  warn "  script in OCI Cloud Shell whenever IDCS objects need changes."
else
  # Idempotency check: list existing grants matching grantee + the
  # entitlement value (the AppRole OCID lives inside entitlement, NOT
  # as a top-level appRole field — that's an IDCS schema quirk).
  GRANT_QUERY=$(printf '%s' "grantee.value eq \"$GROUP_OCID\" and entitlement.attributeValue eq \"$ADMIN_ROLE_OCID\"" | jq -sRr @uri)
  GRANT_LIST=$("${OCI_CLI[@]}" raw-request \
    --target-uri "${DOMAIN_URL}/admin/v1/Grants?filter=${GRANT_QUERY}" \
    --http-method GET --output json 2>/dev/null || echo '{"data":{"Resources":[]}}')
  EXISTING_GRANT_OCID=$(jq -r '(.data.Resources // .data.resources // [])[0].id // empty' <<<"$GRANT_LIST")

  if [[ -n "$EXISTING_GRANT_OCID" ]]; then
    say "  ✓ grant already in place ($EXISTING_GRANT_OCID)"
  else
    say "  creating grant"
    # IDCS Grant schema for ADMINISTRATOR_TO_GROUP requires the role
    # OCID to be passed inside `entitlement` with attributeName="appRoles"
    # and attributeValue=<role_ocid>. The intuitive top-level `appRole`
    # field is silently ignored and the API returns a 400 with
    # "entitlement attributeName is null or empty".
    GRANT_BODY=$(cat <<JSON
{
  "schemas": ["urn:ietf:params:scim:schemas:oracle:idcs:Grant"],
  "grantee": {"type": "Group", "value": "$GROUP_OCID"},
  "app": {"value": "$ADMIN_APP_OCID"},
  "entitlement": {
    "attributeName": "appRoles",
    "attributeValue": "$ADMIN_ROLE_OCID"
  },
  "grantMechanism": "ADMINISTRATOR_TO_GROUP"
}
JSON
)
    GRANT_RESP=$("${OCI_CLI[@]}" raw-request \
      --target-uri "${DOMAIN_URL}/admin/v1/Grants" \
      --http-method POST --request-body "$GRANT_BODY" --output json 2>&1 || true)
    NEW_GRANT_OCID=$(jq -r '.data.id // empty' <<<"$GRANT_RESP" 2>/dev/null || echo "")
    if [[ -z "$NEW_GRANT_OCID" ]]; then
      warn "  Grant create did not return an OCID; raw response:"
      printf '%s\n' "$GRANT_RESP" | head -c 800 >&2
      warn "  Continuing — but self-heal from CI may not work until you grant"
      warn "  '$GROUP_NAME' the Identity Domain Administrator role manually:"
      warn "    Identity Domain → Default → Oracle Cloud Services → Domain Administration → Application roles → Identity Domain Administrator → Manage → Assigned groups → +Add → $GROUP_NAME"
    else
      say "  ✓ granted ($NEW_GRANT_OCID)"
    fi
  fi
fi

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
  if [[ -t 0 ]]; then
    read -r -p "Paste the client_secret (empty = keep existing encrypted auth.yaml if present): " CLIENT_SECRET || true
  else
    warn "stdin is not a TTY — will keep existing encrypted auth.yaml if present"
  fi
fi

say "  app:     $APP_OCID"
say "  clientID: $CLIENT_ID"

# =========================================================================
# 6. IDENTITY PROPAGATION TRUST
# =========================================================================
say "Ensuring Identity Propagation Trust '$TRUST_NAME'"

# OCI CLI sometimes prints ServiceError / usage text on stdout with a non-
# zero exit, or (worse) non-JSON on stdout with exit 0. Under set -e, a
# bare `jq ... <<<"$out"` then aborts with "parse error: Invalid numeric
# literal". Always coerce to JSON before jq.
oci_stdout_json() {
  # Runs "$@"; prints valid JSON on stdout, or empty string if unusable.
  local out
  out=$("$@" 2>/dev/null) || out=""
  if [[ -n "$out" ]] && printf '%s' "$out" | jq empty 2>/dev/null; then
    printf '%s' "$out"
  else
    printf ''
  fi
}

# Identity-domains list payloads use either .data.resources or
# .data.Resources depending on CLI version / raw vs typed subcommand.
trust_list_first_id() {
  jq -r '(.data.resources // .data.Resources // .resources // [])[0].id // empty' 2>/dev/null || true
}
trust_list_by_issuer() {
  # $1 = issuer URL. Prints "id\tname" for first match, or empty.
  local iss="$1"
  jq -r --arg iss "$iss" '
    [ (.data.resources // .data.Resources // .resources // [])[]?
      | select((.issuer // "") == $iss)
    ] | (.[0] // empty) | if . == null or . == "" then empty else "\(.id)\t\(.name // .id)" end
  ' 2>/dev/null || true
}

# First look up by name (normal case). Also try the legacy trust name so
# re-runs after the stawi rename still bind the existing object.
TRUST_LIST=$(oci_stdout_json "${OCI_CLI[@]}" identity-domains identity-propagation-trusts list \
  "${ID_ENDPOINT[@]}" --filter "name eq \"$TRUST_NAME\"" --output json)
TRUST_OCID=""
if [[ -n "$TRUST_LIST" ]]; then
  TRUST_OCID=$(printf '%s' "$TRUST_LIST" | trust_list_first_id)
fi
if [[ -z "$TRUST_OCID" && "$TRUST_NAME" != "github-actions-antinvestor" ]]; then
  TRUST_LIST=$(oci_stdout_json "${OCI_CLI[@]}" identity-domains identity-propagation-trusts list \
    "${ID_ENDPOINT[@]}" --filter "name eq \"github-actions-antinvestor\"" --output json)
  if [[ -n "$TRUST_LIST" ]]; then
    TRUST_OCID=$(printf '%s' "$TRUST_LIST" | trust_list_first_id)
    [[ -n "$TRUST_OCID" ]] && say "  found legacy trust name github-actions-antinvestor ($TRUST_OCID)"
  fi
fi

# Fall back to issuer match. OCI enforces issuer uniqueness, so a prior
# failed run may have left a trust with a different name but same issuer.
if [[ -z "$TRUST_OCID" ]]; then
  TRUST_ALL=$(oci_stdout_json "${OCI_CLI[@]}" identity-domains identity-propagation-trusts list \
    "${ID_ENDPOINT[@]}" --all --output json)
  if [[ -z "$TRUST_ALL" ]]; then
    # Typed subcommand flaky on some CLI builds — fall back to raw SCIM list.
    TRUST_ALL=$(oci_stdout_json "${OCI_CLI[@]}" raw-request \
      --target-uri "${DOMAIN_URL}/admin/v1/IdentityPropagationTrusts?count=100" \
      --http-method GET --output json)
  fi
  if [[ -n "$TRUST_ALL" ]]; then
    trust_hit=$(printf '%s' "$TRUST_ALL" | trust_list_by_issuer "https://token.actions.githubusercontent.com")
    if [[ -n "$trust_hit" ]]; then
      TRUST_OCID=$(printf '%s' "$trust_hit" | cut -f1)
      EXISTING_NAME=$(printf '%s' "$trust_hit" | cut -f2-)
      warn "Trust with GitHub issuer already exists under a different name: '$EXISTING_NAME' ($TRUST_OCID)"
      warn "Reusing it. If you need the impersonation rule updated, delete it in the UI:"
      warn "  Identity Domain → Security → Identity Propagation Trusts → $EXISTING_NAME → Delete"
      warn "  Then re-run this script."
    fi
  else
    warn "  could not list identity-propagation-trusts as JSON; will attempt create"
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
  TRUST_RAW=$(oci_stdout_json "${OCI_CLI[@]}" raw-request \
    --target-uri "${DOMAIN_URL}/admin/v1/IdentityPropagationTrusts/${TRUST_OCID}?attributes=clientClaimName,clientClaimValues,subjectMappingAttribute,impersonationServiceUsers" \
    --http-method GET --output json)
  if [[ -z "$TRUST_RAW" ]]; then
    TRUST_RAW='{"data":{}}'
  fi

  has_field() {
    # Top-level normalised field present + non-empty.
    local target="$1"
    jq -r --arg t "$target" '
      (.data // .) | to_entries[]?
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
    (.data."impersonation-service-users" // .data.impersonationServiceUsers // .impersonationServiceUsers // [])
    | (.[0] // {}).rule // ""
  ' <<<"$TRUST_RAW" 2>/dev/null || echo "")
  trust_user_value=$(jq -r '
    (.data."impersonation-service-users" // .data.impersonationServiceUsers // .impersonationServiceUsers // [])
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
  TRUST_CREATE=$(oci_stdout_json "${OCI_CLI[@]}" identity-domains identity-propagation-trust create \
    "${ID_ENDPOINT[@]}" --from-json "$TRUST_PAYLOAD" --output json)
  if [[ -z "$TRUST_CREATE" ]]; then
    # Typed create can fail/print non-JSON on older CLI — raw SCIM POST.
    say "  typed create returned no JSON; trying raw SCIM POST"
    TRUST_CREATE=$(oci_stdout_json "${OCI_CLI[@]}" raw-request \
      --target-uri "${DOMAIN_URL}/admin/v1/IdentityPropagationTrusts" \
      --http-method POST \
      --request-body "$TRUST_PAYLOAD" \
      --output json)
  fi
  TRUST_OCID=$(jq -r '.data.id // .id // empty' <<<"${TRUST_CREATE:-{}}" 2>/dev/null || true)
  if [[ -z "$TRUST_OCID" ]]; then
    warn "  trust create response (truncated):"
    printf '%s\n' "${TRUST_CREATE:-<empty>}" | head -c 800 >&2
    die "Identity Propagation Trust create failed — see response above."
  fi
fi
say "  trust:   $TRUST_OCID"

# =========================================================================
# 7. WRITE ENCRYPTED auth.yaml + EDIT accounts.yaml + COMMIT + PR
# =========================================================================
say ""
say "=========================================================="
say "OCI workload identity federation ready for profile [$PROFILE]."

BRANCH="${BRANCH:-onboard-oracle-${GH_PROFILE}}"

# Isolated worktree from origin/$BASE_BRANCH so we never disturb the
# operator's current branch / dirty tree. Reuses the branch tip if it
# already exists on the remote.
say "preparing worktree for branch '$BRANCH' from origin/$BASE_BRANCH"
# Authenticated fetch when GITHUB_TOKEN is set (private repo / Cloud Shell).
github_git_fetch "refs/heads/${BASE_BRANCH}:refs/remotes/origin/${BASE_BRANCH}" \
  || die "git fetch origin $BASE_BRANCH failed (set GITHUB_TOKEN or git credentials)"
# Best-effort: also refresh the feature branch tip if it already exists remotely.
github_git_fetch "refs/heads/${BRANCH}:refs/remotes/origin/${BRANCH}" 2>/dev/null || true

ONBOARD_WORKTREE="${TMPDIR:-/tmp}/bootstrap-onboard-${GH_PROFILE}-$$"
rm -rf "$ONBOARD_WORKTREE"
if git -C "$REPO_PATH" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  git -C "$REPO_PATH" worktree add -B "$BRANCH" "$ONBOARD_WORKTREE" "origin/$BRANCH" \
    || die "git worktree add (existing branch) failed"
  # Keep the onboard branch current with main so the PR is mergeable.
  git -C "$ONBOARD_WORKTREE" merge --ff-only "origin/$BASE_BRANCH" 2>/dev/null \
    || git -C "$ONBOARD_WORKTREE" rebase "origin/$BASE_BRANCH" 2>/dev/null \
    || warn "could not fast-forward/rebase onto origin/$BASE_BRANCH; continuing on existing tip"
else
  git -C "$REPO_PATH" worktree add -B "$BRANCH" "$ONBOARD_WORKTREE" "origin/$BASE_BRANCH" \
    || die "git worktree add from origin/$BASE_BRANCH failed"
fi
ONBOARD_WORKTREE_CLEANUP="true"

# Paths are strictly scoped to this GH_PROFILE so one account never rewrites
# another account's auth.yaml (or any other provider tree).
AUTH_REL="tofu/shared/accounts/oracle/${GH_PROFILE}/auth.yaml"
AUTH_DIR="$ONBOARD_WORKTREE/tofu/shared/accounts/oracle/$GH_PROFILE"
AUTH_FILE="$ONBOARD_WORKTREE/$AUTH_REL"
ACCOUNTS_FILE="$ONBOARD_WORKTREE/tofu/shared/accounts.yaml"
AUTH_CHANGED="false"
ACCOUNTS_CHANGED="false"

mkdir -p "$AUTH_DIR"

VCN_CIDR_EFF="${VCN_CIDR:-10.200.0.0/16}"
auth_is_sops_encrypted() {
  [[ -f "$1" ]] && grep -qE '^sops:' "$1"
}

# True when existing encrypted auth decrypts and matches this run's desired
# values for GH_PROFILE only. Needs age private key (SOPS_AGE_KEY / keys.txt).
# When CLIENT_SECRET is empty, the secret half of oidc_client_identifier is
# not compared (so re-runs without the secret can still short-circuit).
auth_fields_match_existing() {
  local plain_json oidc want_oidc_prefix
  plain_json=$(sops -d --input-type yaml --output-type json "$AUTH_FILE" 2>/dev/null) || return 1
  oidc=$(jq -r '.auth.oidc_client_identifier // .oidc_client_identifier // empty' <<<"$plain_json")
  [[ -n "$oidc" && "$oidc" == *:* ]] || return 1
  want_oidc_prefix="${CLIENT_ID}:"
  [[ "$oidc" == "${want_oidc_prefix}"* ]] || return 1
  if [[ -n "$CLIENT_SECRET" && "$oidc" != "${CLIENT_ID}:${CLIENT_SECRET}" ]]; then
    return 1
  fi
  jq -e \
    --arg tenancy "$TENANCY_OCID" \
    --arg region "$REGION" \
    --arg compartment "$COMPARTMENT_OCID" \
    --arg domain "$DOMAIN_BASE_URL" \
    --arg vcn "$VCN_CIDR_EFF" \
    '
      (.auth // .) as $a
      | ($a.tenancy_ocid // "") == $tenancy
      and ($a.region // "") == $region
      and ($a.compartment_ocid // "") == $compartment
      and (($a.domain_base_url // "") | rtrimstr("/")) == ($domain | rtrimstr("/"))
      and (($a.vcn_cidr // "10.200.0.0/16") == $vcn)
      and (($a.auth_method // "SecurityToken") == "SecurityToken")
    ' <<<"$plain_json" >/dev/null 2>&1
}

write_encrypted_auth() {
  [[ -n "$CLIENT_SECRET" ]] || die "client_secret is required to create/update auth.yaml for ${GH_PROFILE}"
  cat > "$AUTH_FILE" <<EOF
auth:
  tenancy_ocid: ${TENANCY_OCID}
  region: ${REGION}
  compartment_ocid: ${COMPARTMENT_OCID}
  vcn_cidr: ${VCN_CIDR_EFF}
  enable_ipv6: true
  auth_method: SecurityToken
  domain_base_url: ${DOMAIN_BASE_URL}
  oidc_client_identifier: "${CLIENT_ID}:${CLIENT_SECRET}"
EOF
  (cd "$ONBOARD_WORKTREE" && sops -e --input-type yaml --output-type yaml -i "$AUTH_REL") \
    || die "sops encrypt failed for ${AUTH_REL}"
  AUTH_CHANGED="true"
  say "wrote encrypted $AUTH_REL (account ${GH_PROFILE} only)"
}

if auth_is_sops_encrypted "$AUTH_FILE"; then
  if auth_fields_match_existing; then
    say "existing encrypted $AUTH_REL is current — not regenerating"
  elif [[ -z "$CLIENT_SECRET" ]]; then
    # Re-run without secret: never clobber a good encrypted file.
    say "preserving existing encrypted $AUTH_REL (no client_secret this run; leave file unchanged)"
    warn "  to force rewrite: paste client_secret when prompted or regenerate the OAuth secret"
  else
    say "updating encrypted $AUTH_REL (fields or secret changed for ${GH_PROFILE})"
    write_encrypted_auth
  fi
else
  write_encrypted_auth
fi

# Idempotent edit of accounts.yaml: append ONLY this account under oracle:.
# Never rewrites other list entries or other top-level keys.
if ! grep -qE "^[[:space:]]*-[[:space:]]+${GH_PROFILE}[[:space:]]*\$" "$ACCOUNTS_FILE"; then
  python3 - "$ACCOUNTS_FILE" "$GH_PROFILE" <<'PY'
import sys, re
path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out = []
in_oracle = False
inserted = False
for line in lines:
    if re.match(r'^oracle:\s*$', line):
        in_oracle = True
        out.append(line)
        continue
    if in_oracle and not inserted:
        if line.startswith('  -') or line.startswith('  #') or line.strip() == '':
            out.append(line)
            continue
        # First non-list / non-comment / non-blank line — we've left
        # the oracle block. Insert before it.
        out.append(f"  - {name}")
        inserted = True
    out.append(line)
if in_oracle and not inserted:
    out.append(f"  - {name}")
open(path, 'w').write('\n'.join(out) + '\n')
PY
  ACCOUNTS_CHANGED="true"
  say "added '$GH_PROFILE' to oracle: in tofu/shared/accounts.yaml"
else
  say "'$GH_PROFILE' already in accounts.yaml — skipping edit"
fi

cd "$ONBOARD_WORKTREE"
# Commit identity: prefer repo/global git config, else a non-interactive fallback
# so Cloud Shell / fresh clones don't fail with "please tell me who you are".
git_user_name=$(git config user.name 2>/dev/null || true)
git_user_email=$(git config user.email 2>/dev/null || true)
[[ -n "$git_user_name" ]] || git_user_name="bootstrap-oci-oidc"
[[ -n "$git_user_email" ]] || git_user_email="${BUDGET_EMAIL:-bootstrap-oci-oidc@users.noreply.github.com}"

# Stage only this account's auth + accounts.yaml (never other accounts/*).
git add -- "$AUTH_REL" "tofu/shared/accounts.yaml"
if git diff --cached --quiet; then
  say "no file changes to commit for ${GH_PROFILE}"
else
  git -c "user.name=${git_user_name}" -c "user.email=${git_user_email}" \
    commit -m "onboard oracle ${GH_PROFILE}: add to accounts.yaml + encrypted auth"
  say "committed onboard changes on branch '$BRANCH' (scoped to ${GH_PROFILE})"
fi

compare_url="https://github.com/${GH_REPO}/compare/${BASE_BRANCH}...${BRANCH}?expand=1"

if [[ "$NO_PUSH" = "true" ]]; then
  say "branch '$BRANCH' committed in worktree — skipping push/PR (--no-push)"
  say "worktree: $ONBOARD_WORKTREE"
  say "later: push and open $compare_url"
  ONBOARD_WORKTREE_CLEANUP="false"
else
  say "pushing branch '$BRANCH' → github.com/${GH_REPO} (token auth, non-interactive)"
  git -C "$ONBOARD_WORKTREE" remote set-url origin "$DEFAULT_REPO_URL" 2>/dev/null || true
  push_err=$(mktemp)
  if ! github_git -C "$ONBOARD_WORKTREE" push origin "refs/heads/${BRANCH}:refs/heads/${BRANCH}" 2>"$push_err"; then
    # Redact anything that might echo the token.
    sed -E 's#x-access-token:[^@[:space:]]+#x-access-token:***#g; s#[Bb]earer [A-Za-z0-9._-]+#Bearer ***#g' \
      "$push_err" >&2 || true
    rm -f "$push_err"
    die "git push failed — check GITHUB_TOKEN has Contents: R/W on ${GH_REPO}"
  fi
  rm -f "$push_err"
  say "pushed $BRANCH"

  pr_url=""
  if [[ "$NO_PR" = "true" ]]; then
    pr_url="$compare_url"
    say "--no-pr: open manually → $pr_url"
  elif [[ -z "$(github_token)" ]]; then
    pr_url="$compare_url"
    warn "no GITHUB_TOKEN — cannot open PR via API. Open: $pr_url"
  else
    existing_pr=$(github_find_open_pr "$BRANCH" "$BASE_BRANCH")
    if [[ -n "$existing_pr" ]]; then
      pr_url="$existing_pr"
      say "existing open PR: $pr_url"
    else
      pr_body=$(cat <<PRBODY
## Summary
Onboard OCI tenancy / account \`${GH_PROFILE}\` for GitHub Actions WIF.

- Encrypted \`tofu/shared/accounts/oracle/${GH_PROFILE}/auth.yaml\` (OIDC client + tenancy metadata)
- Listed under \`oracle:\` in \`tofu/shared/accounts.yaml\`

## After merge
Workflow [\`onboard-oracle\`](https://github.com/${GH_REPO}/actions/workflows/onboard-oracle.yml) runs on push to \`${BASE_BRANCH}\` when these paths change:

1. **Seed free-tier capacity** — empty accounts get a continuous Always Free worker in R2 \`nodes.yaml\`
2. **cluster-provision (mode=full)** — Talos image import per tenancy → \`tofu-apply\` (new account matrix cell) → Omni cluster template sync

That provisions compute in the new tenancy and expands the cluster machine sets as nodes register.

## Test plan
- [ ] PR \`tofu-plan\` green for \`02-oracle-infra\` matrix cell \`${GH_PROFILE}\` (may warn if R2 inventory empty until post-merge seed)
- [ ] Merge to \`${BASE_BRANCH}\`
- [ ] Confirm \`onboard-oracle\` workflow succeeds
- [ ] \`omnictl get machines\` shows the new node(s) joining

Generated by \`scripts/bootstrap-oci-oidc.sh\` for OCI profile \`${PROFILE}\`.
PRBODY
)
      pr_url=$(github_create_pr \
        "onboard oracle ${GH_PROFILE}: WIF auth + accounts.yaml" \
        "$BRANCH" "$BASE_BRANCH" "$pr_body") \
        || pr_url=""
      if [[ -n "$pr_url" ]]; then
        say "opened PR: $pr_url"
      else
        pr_url="$compare_url"
        warn "PR API create failed — open manually: $pr_url"
      fi
    fi
  fi
  say ""
  say "PR: $pr_url"
  say "After merge, CI workflow onboard-oracle expands the cluster for '${GH_PROFILE}'."
fi

# =========================================================================
# 8. BUDGET + ALERT (cost guardrail)
# =========================================================================
# Per-account budget object so onboarding tenancy A never mutates B's cap.
# Hard ceiling $2/month. Re-runs do not randomize; only create if missing,
# or clamp down if an existing amount exceeds the max.
if [[ -z "$BUDGET_NAME" ]]; then
  BUDGET_NAME="stawi-${GH_PROFILE}-budget"
fi
# Clamp to integer 1..BUDGET_AMOUNT_MAX (default max = 2).
if ! [[ "$BUDGET_AMOUNT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  warn "BUDGET_AMOUNT='$BUDGET_AMOUNT' not numeric — using ${BUDGET_AMOUNT_MAX}"
  BUDGET_AMOUNT="$BUDGET_AMOUNT_MAX"
fi
BUDGET_AMOUNT=$(awk -v a="$BUDGET_AMOUNT" -v m="$BUDGET_AMOUNT_MAX" 'BEGIN{
  # floor to int dollars for OCI budget API friendliness
  v=int(a+0);
  if (v < 1) v=1;
  if (v > m) v=m;
  print v
}')
say ""
say "Ensuring budget '$BUDGET_NAME' (USD ${BUDGET_AMOUNT}/month max ${BUDGET_AMOUNT_MAX}, target compartment $COMPARTMENT_OCID)"
# Budgets live in the tenancy root compartment; target is the cluster compt.
BUDGETS_ENDPOINT_LIST="https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets?compartmentId=${TENANCY_OCID}&displayName=${BUDGET_NAME}"
BUDGET_LIST=$("${OCI_CLI[@]}" raw-request \
  --target-uri "$BUDGETS_ENDPOINT_LIST" --http-method GET --output json 2>/dev/null || echo '{"data":[]}')
if ! printf '%s' "$BUDGET_LIST" | jq empty 2>/dev/null; then
  warn "  budget list returned non-JSON (api disabled in region?); treating as empty"
  BUDGET_LIST='{"data":[]}'
fi
BUDGET_OCID=$(jq -r '.data[0].id // empty' <<<"$BUDGET_LIST")
EXISTING_BUDGET_AMT=$(jq -r '.data[0].amount // empty' <<<"$BUDGET_LIST")

if [[ -z "$BUDGET_OCID" ]]; then
  say "  creating (via raw-request — older oci-cli versions lack the create subcommand)"
  BUDGETS_ENDPOINT="https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets"
  BUDGET_BODY=$(jq -n \
    --arg cid "$TENANCY_OCID" --arg name "$BUDGET_NAME" --arg desc "Cluster cost guardrail for oracle/${GH_PROFILE}; tracks $COMPARTMENT_OCID" \
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
  # Only update when existing amount exceeds the hard ceiling — never raise
  # and never thrash a stable ≤$2 budget on re-run.
  need_clamp="false"
  if [[ -n "$EXISTING_BUDGET_AMT" ]]; then
    awk -v a="$EXISTING_BUDGET_AMT" -v m="$BUDGET_AMOUNT_MAX" 'BEGIN{exit !(a+0 > m)}' \
      && need_clamp="true"
  fi
  if [[ "$need_clamp" == "true" ]]; then
    say "  exists ($BUDGET_OCID) amount=${EXISTING_BUDGET_AMT} > max ${BUDGET_AMOUNT_MAX}; clamping to ${BUDGET_AMOUNT}"
    UPD_BODY=$(jq -n --argjson amt "$BUDGET_AMOUNT" '{amount: $amt}')
    "${OCI_CLI[@]}" raw-request \
      --target-uri "https://usage.${REGION}.oci.oraclecloud.com/20190111/budgets/${BUDGET_OCID}" \
      --http-method PUT --request-body "$UPD_BODY" --output json >/dev/null 2>&1 || \
      warn "  budget clamp update returned non-zero"
  else
    say "  exists ($BUDGET_OCID) amount=${EXISTING_BUDGET_AMT:-unknown} — leaving unchanged"
  fi
fi
say "  budget:  $BUDGET_OCID"

# Alert rules: forecasted-spend ladder at 1, 3, 15, 50, 80, 100 percent of
# cap. type=FORECAST means OCI uses its own usage-projection model (not
# realised spend) to decide when to fire — operator gets a heads-up the
# moment the cluster's burn rate would exceed each threshold by month-end,
# days before realised spend reaches the same point. 1% is the early
# tripwire on the always-free baseline ($0 expected); the higher tiers
# track ongoing severity if it does start spending. Each rule is keyed by
# display_name so re-runs are idempotent.
if [[ -n "$BUDGET_OCID" && -n "$BUDGET_EMAIL" ]]; then
  for THRESHOLD in 1 3 15 50 80 100; do
    ALERT_NAME=$(printf 'alert-%03dpct-forecast' "$THRESHOLD")
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
        --arg msg "Budget ${BUDGET_NAME} forecast hit ${THRESHOLD}% of monthly cap (\$${BUDGET_AMOUNT}). Investigate paid resources." '{
          displayName:   $name,
          type:          "FORECAST",
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
