#!/usr/bin/env bash
# scripts/bootstrap-gcp-wif.sh
#
# Idempotently configure GCP Workload Identity Federation for GitHub Actions
# OIDC, then (only if the account is not already on the base branch) open a
# PR that lands the encrypted auth + accounts.yaml entry.
#
#   GitHub JWT  →  WIF pool/provider (github / github-actions)
#                       ↓ attribute.repository == stawi-org/deployment.infra
#                  SA tofu-gcp@PROJECT  (roles/iam.workloadIdentityUser)
#                       ↓ impersonation
#                  OpenTofu / image-import ADC in CI
#
# ── SAFETY CONTRACT (cluster always stays up) ────────────────────────────
# This script is SAFE TO RUN AT ANY TIME on a live production project.
# It MUST NOT and does not:
#   - create, stop, start, delete, or resize GCE VMs / disks / snapshots
#   - create or destroy VPCs, subnets, or firewall rules (OpenTofu owns those)
#   - wipe Omni / Kubernetes / Talos cluster state
#   - revoke or remove existing IAM bindings (only adds missing ones)
#   - delete the WIF pool, SA, or image bucket
#   - run OpenTofu apply or cluster-provision
#
# Re-runs only ENSURE (create-if-missing / bind-if-missing) WIF, SA roles,
# bucket IAM, and budget. If auth already exists on origin/<base> for this
# --gh-profile, the script skips the git/PR path so onboard-gcp is not
# re-triggered. Use --force-repo-write to rewrite auth intentionally.
#
# Prereqs (everything else is fetched/installed by this script):
#   - gcloud CLI installed and authed to the target project (Owner or
#     equivalent for IAM + service usage + billing budgets)
#   - Network access to github.com (public clone of deployment.infra)
#   - jq, curl, python3, git (pre-installed on GCP Cloud Shell)
#
# Standalone Cloud Shell flow (only this file needs to be uploaded):
#   ./bootstrap-gcp-wif.sh --project YOUR_PROJECT_ID --gh-profile my-acct
#
# Encryption uses the public age key in .sops.yaml — no private age key
# is required on the bootstrap machine.
#
# Usage:
#   ./bootstrap-gcp-wif.sh --project YOUR_PROJECT_ID
#   ./bootstrap-gcp-wif.sh --project p --gh-profile demo --region europe-west9
#   ./bootstrap-gcp-wif.sh --project p --iam-only          # never touch git
#   ./bootstrap-gcp-wif.sh --project p --force-repo-write  # rewrite auth PR
#   ./bootstrap-gcp-wif.sh --project p --no-push
#
# Re-running is safe. GCP resources are looked up by name; missing ones are
# created. Existing IAM is left in place. The branch is reused if present.

set -euo pipefail

# Fully non-interactive: never hang on Username/Password or credential prompts.
# (Cloud Shell has no GitHub credentials by default; we use a token or skip push.)
export GIT_TERMINAL_PROMPT=0
export GIT_ASKPASS="${GIT_ASKPASS:-/bin/true}"
export SSH_ASKPASS="${SSH_ASKPASS:-/bin/true}"
# Never hang on SSH passphrase / host key prompts either.
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new}"
# Disable credential helpers for this process (avoids desktop/store prompts).
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=credential.helper
export GIT_CONFIG_VALUE_0=
# sops auto-install lands here; Cloud Shell often lacks it on PATH by default.
export PATH="${HOME}/.local/bin:${PATH}"

# -------- defaults --------
PROJECT=""
# Closest French GCP region to Marseille (no eu-marseille on GCE).
# Pair with OCI for databases (eu-frankfurt-1 / future eu-marseille-1).
REGION="europe-west9"
VPC_CIDR="10.210.0.0/24"
GH_PROFILE=""
REPO_PATH=""
BASE_BRANCH="main"
BRANCH=""
NO_PUSH="false"
NO_PR="false"
# Auto-clone is the default: Cloud Shell operators only upload this script.
# --no-clone forces fail-fast if no checkout is found (CI / strict mode).
NO_CLONE="false"
NO_BUDGET="false"
# IAM-only: ensure GCP resources; never open a git worktree / PR.
# Default auto-skips repo write when auth already exists on base branch.
IAM_ONLY="false"
FORCE_REPO_WRITE="false"
# Monthly cost tripwire for Spot workers. Default $50 matches the operator
# budget target (2×e2-standard-2 pack leaves headroom). Override with
# --budget-amount or env BUDGET_AMOUNT=N. Not a hard provisioner stop.
BUDGET_AMOUNT="${BUDGET_AMOUNT:-50}"
# Alert recipient for billing-account IAM defaults. If unset, defaults to
# `git config user.email`. Override with --budget-email / BUDGET_EMAIL.
# Budget is still created without email (console + billing-admin defaults).
BUDGET_EMAIL="${BUDGET_EMAIL:-}"
BUDGET_NAME="${BUDGET_NAME:-stawi-gcp-workers}"

WIF_POOL="github"
WIF_PROVIDER="github-actions"
SA_ID="tofu-gcp"
GITHUB_REPO="stawi-org/deployment.infra"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
ATTR_CONDITION="assertion.repository=='${GITHUB_REPO}'"
ATTR_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref"

SOPS_VERSION="v3.11.0"
CLONE_URL="https://github.com/${GITHUB_REPO}.git"
DEFAULT_CLONE_DIR="${HOME}/deployment.infra"

usage() {
  # Prefer the header comment block when BASH_SOURCE is a real file (not a pipe).
  if [[ -n "${BASH_SOURCE[0]:-}" && -r "${BASH_SOURCE[0]}" ]]; then
    awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
      "${BASH_SOURCE[0]}"
  else
    cat <<'HDR'
bootstrap-gcp-wif.sh — configure GCP WIF + SOPS auth PR for deployment.infra
HDR
  fi
  cat <<'EOF'

Flags:
  --project <ID>         GCP project id (required)
  --region <REGION>      Default europe-west9 (Paris FR; nearest to Marseille)
  --gh-profile <NAME>    accounts.yaml key / auth path segment
                         (default: slug of project id last dash segment)
  --vpc-cidr <CIDR>      Default 10.210.0.0/24
  --repo-path <PATH>     deployment.infra checkout
                         (default: git root, else auto-clone ~/deployment.infra)
  --no-clone             Do not auto-clone; fail if no checkout is found
  --clone                Accepted for back-compat (auto-clone is already default)
  --base-branch <NAME>   Branch to fork the worktree from (default: main)
  --branch <NAME>        Push branch (default: onboard-gcp-<gh-profile>)
  --no-push              Commit in worktree only; skip push
  --no-pr                Push but do not open a pull request via API
  --iam-only             Ensure GCP IAM/WIF/bucket/budget only; never write git
  --force-repo-write     Rewrite auth + accounts PR even if already onboarded
  --budget-amount <USD>  Monthly Cloud Billing budget (default: 50)
  --budget-email <ADDR>  Hint only (billing admins still get default alerts)
  --budget-name <NAME>   Budget display name (default: stawi-gcp-workers)
  --no-budget            Skip Cloud Billing budget ensure
  -h, --help             Show this help

Cloud Shell (upload only this script to ~):
  ./bootstrap-gcp-wif.sh --project YOUR_PROJECT_ID --gh-profile my-acct

Safe re-run (live cluster — IAM repair only when already onboarded):
  ./bootstrap-gcp-wif.sh --project P --gh-profile my-acct
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --project)          PROJECT="$2"; shift 2 ;;
    --region)           REGION="$2"; shift 2 ;;
    --gh-profile)       GH_PROFILE="$2"; shift 2 ;;
    --vpc-cidr)         VPC_CIDR="$2"; shift 2 ;;
    --repo-path)        REPO_PATH="$2"; shift 2 ;;
    --clone)            NO_CLONE="false"; shift ;;  # default; kept for older docs/invocations
    --no-clone)         NO_CLONE="true"; shift ;;
    --base-branch)      BASE_BRANCH="$2"; shift 2 ;;
    --branch)           BRANCH="$2"; shift 2 ;;
    --no-push)          NO_PUSH="true"; shift ;;
    --no-pr)            NO_PR="true"; shift ;;
    --iam-only)         IAM_ONLY="true"; shift ;;
    --force-repo-write) FORCE_REPO_WRITE="true"; shift ;;
    --budget-amount)    BUDGET_AMOUNT="$2"; shift 2 ;;
    --budget-email)     BUDGET_EMAIL="$2"; shift 2 ;;
    --budget-name)      BUDGET_NAME="$2"; shift 2 ;;
    --no-budget)        NO_BUDGET="true"; shift ;;
    -h|--help)          usage ;;
    *)                  echo "unknown arg: $1" >&2; usage ;;
  esac
done

say()  { printf '\e[1;34m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "${PROJECT:-gcp}" "$*"; }
warn() { printf '\e[1;33m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "${PROJECT:-gcp}" "$*" >&2; }
die()  { printf '\e[1;31m[%s][%s]\e[0m %s\n' "$(date +%H:%M:%S)" "${PROJECT:-gcp}" "$*" >&2; exit 1; }

[[ -n "$PROJECT" ]] || die "--project is required"

# -------- helpers --------
ensure_sops() {
  if command -v sops >/dev/null 2>&1; then
    return 0
  fi
  local dest="${HOME}/.local/bin"
  local arch
  arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "unsupported arch for sops auto-install: $arch (install sops manually)" ;;
  esac
  mkdir -p "$dest"
  say "sops not on PATH; installing ${SOPS_VERSION} → ${dest}/sops"
  curl -fsSL -o "${dest}/sops" \
    "https://github.com/getsops/sops/releases/download/${SOPS_VERSION}/sops-${SOPS_VERSION}.linux.${arch}"
  chmod +x "${dest}/sops"
  export PATH="${dest}:${PATH}"
  command -v sops >/dev/null 2>&1 || die "failed to install sops into ${dest}"
}

github_token() {
  # Never prompt. Sources (first wins): GITHUB_TOKEN, GH_TOKEN, `gh auth token`.
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s' "$GITHUB_TOKEN"
    return 0
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s' "$GH_TOKEN"
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    local t
    t=$(GH_PROMPT_DISABLED=1 gh auth token 2>/dev/null || true)
    if [[ -n "$t" ]]; then
      printf '%s' "$t"
      return 0
    fi
  fi
  return 1
}

github_login() {
  # Authenticated login for the token (owner of a fork), or empty.
  local token="${1:-}"
  [[ -n "$token" ]] || return 1
  curl -fsS -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/user" 2>/dev/null \
    | jq -r '.login // empty'
}

github_ensure_fork() {
  # Ensure token owner has a fork of GITHUB_REPO; print "owner/repo".
  local token="$1"
  local login fork_full
  login=$(github_login "$token") || true
  [[ -n "$login" ]] || return 1
  fork_full="${login}/${GITHUB_REPO#*/}"
  # Already exists?
  if curl -fsS -o /dev/null -w '%{http_code}' \
      -H "Authorization: Bearer ${token}" \
      -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${fork_full}" 2>/dev/null | grep -qx '200'; then
    printf '%s' "$fork_full"
    return 0
  fi
  say "creating fork ${fork_full} (no write access to ${GITHUB_REPO})"
  local code
  code=$(curl -sS -o /tmp/gcp-fork.json -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/${GITHUB_REPO}/forks" || true)
  if [[ "$code" != "202" && "$code" != "200" ]]; then
    warn "fork create HTTP ${code}: $(head -c 300 /tmp/gcp-fork.json 2>/dev/null || true)"
    return 1
  fi
  # Forks are async — wait until the repo is readable.
  local i
  for ((i = 1; i <= 30; i++)); do
    if curl -fsS -o /dev/null \
        -H "Authorization: Bearer ${token}" \
        "https://api.github.com/repos/${fork_full}" 2>/dev/null; then
      printf '%s' "$fork_full"
      return 0
    fi
    sleep 2
  done
  warn "fork ${fork_full} not ready after 60s"
  return 1
}

git_push_noninteractive() {
  # Args: remote_url refspec. Never prompts; returns 0 on success.
  local url="$1" refspec="$2"
  # Strip any interactive helpers; force terminal prompt off.
  GIT_TERMINAL_PROMPT=0 \
  GIT_ASKPASS=/bin/true \
  git -c credential.helper= -c core.askPass=/bin/true \
    push --porcelain "$url" "$refspec" 2>/tmp/gcp-git-push.err
}

github_api() {
  # github_api METHOD PATH [curl body args...]
  local method="$1" path="$2"
  shift 2
  local token
  token="$(github_token)" || die "GITHUB_TOKEN or GH_TOKEN required for GitHub API (${method} ${path})"
  curl -fsS -X "$method" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com${path}" \
    "$@"
}

github_create_pr() {
  local title="$1" head="$2" base="$3" body="$4"
  local payload resp pr_url
  payload=$(jq -n \
    --arg title "$title" \
    --arg head "$head" \
    --arg base "$base" \
    --arg body "$body" \
    '{title:$title, head:$head, base:$base, body:$body}')
  # 422 when an open PR already exists for this head — treat as success.
  resp=$(curl -sS -X POST \
    -H "Authorization: Bearer $(github_token)" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://api.github.com/repos/${GITHUB_REPO}/pulls" \
    -w '\n%{http_code}')
  local code body_json
  code=$(printf '%s\n' "$resp" | tail -1)
  body_json=$(printf '%s\n' "$resp" | sed '$d')
  if [[ "$code" == "201" ]]; then
    pr_url=$(jq -r '.html_url // empty' <<<"$body_json")
    say "opened PR: $pr_url"
    printf '%s\n' "$pr_url"
    return 0
  fi
  if [[ "$code" == "422" ]]; then
    # Already exists — look up open PR for this head.
    # head may already be "owner:branch" (fork) or plain "branch" (same-repo).
    local head_q existing
    if [[ "$head" == *:* ]]; then
      head_q="$head"
    else
      head_q="${GITHUB_REPO%%/*}:${head}"
    fi
    # URL-encode colon is fine as-is for GitHub's head query.
    existing=$(github_api GET \
      "/repos/${GITHUB_REPO}/pulls?head=${head_q}&state=open" \
      || true)
    pr_url=$(jq -r '.[0].html_url // empty' <<<"$existing")
    if [[ -n "$pr_url" ]]; then
      say "PR already open: $pr_url"
      printf '%s\n' "$pr_url"
      return 0
    fi
  fi
  warn "create PR failed (HTTP ${code}):"
  printf '%s\n' "$body_json" | head -c 800 >&2
  printf '\n' >&2
  return 1
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]-' | sed -E 's/-+/-/g; s/^-|-$//g'
}

ensure_git_clone() {
  # Populate $1 with a usable deployment.infra checkout (clone or update).
  local dest="$1"
  if [[ -d "$dest/.git" && -f "$dest/.sops.yaml" ]]; then
    say "reusing existing clone at $dest"
    git -C "$dest" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null \
      || warn "could not fetch origin/${BASE_BRANCH} (using local clone as-is)"
    # Prefer a clean main tip when the clone is only used as a worktree base.
    git -C "$dest" checkout "$BASE_BRANCH" --quiet 2>/dev/null \
      || git -C "$dest" checkout -B "$BASE_BRANCH" "origin/${BASE_BRANCH}" --quiet 2>/dev/null \
      || true
    git -C "$dest" pull --ff-only origin "$BASE_BRANCH" --quiet 2>/dev/null || true
    return 0
  fi
  if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
    die "$dest exists but is not a git clone — remove it or pass --repo-path elsewhere"
  fi
  say "cloning ${CLONE_URL} → ${dest}"
  mkdir -p "$(dirname "$dest")"
  if ! git clone --branch "$BASE_BRANCH" --single-branch "$CLONE_URL" "$dest"; then
    # Fallback without --branch in case default branch rename race.
    git clone "$CLONE_URL" "$dest" \
      || die "git clone failed — need network access to github.com/${GITHUB_REPO}"
  fi
}

resolve_repo_path() {
  # Standalone-first: Cloud Shell operators upload only this script to ~.
  # Resolution order:
  #   1) explicit --repo-path (create via clone if missing, unless --no-clone)
  #   2) cwd is already a deployment.infra checkout (.sops.yaml at git root)
  #   3) auto-clone into ~/deployment.infra (default)
  if [[ -n "$REPO_PATH" ]]; then
    if [[ ! -d "$REPO_PATH" || ! -f "$REPO_PATH/.sops.yaml" ]]; then
      if [[ "$NO_CLONE" == "true" ]]; then
        die "--repo-path ${REPO_PATH} is not a deployment.infra checkout (--no-clone set)"
      fi
      ensure_git_clone "$REPO_PATH"
    fi
  else
    local detected
    detected=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$detected" && -f "$detected/.sops.yaml" && -f "$detected/tofu/shared/accounts.yaml" ]]; then
      REPO_PATH="$detected"
      say "using checkout at cwd: $REPO_PATH"
    elif [[ "$NO_CLONE" == "true" ]]; then
      die "Not inside a deployment.infra checkout and --no-clone set. Pass --repo-path or drop --no-clone."
    else
      REPO_PATH="$DEFAULT_CLONE_DIR"
      ensure_git_clone "$REPO_PATH"
    fi
  fi

  REPO_PATH="$(cd "$REPO_PATH" && pwd)"
  [[ -f "$REPO_PATH/.sops.yaml" ]] \
    || die "$REPO_PATH has no .sops.yaml — wrong checkout? Aborting before any write."
  [[ -f "$REPO_PATH/tofu/shared/accounts.yaml" ]] \
    || die "$REPO_PATH missing tofu/shared/accounts.yaml — wrong checkout?"
  say "repo path: $REPO_PATH"
}

verify_gcloud_access() {
  command -v gcloud >/dev/null 2>&1 || die "missing: gcloud (install Cloud SDK or use GCP Cloud Shell)"

  # Active account?
  local active
  active=$(gcloud auth list --filter=status:ACTIVE --format='value(account)' 2>/dev/null | head -1 || true)
  if [[ -z "$active" ]]; then
    # ADC / metadata (Cloud Shell, GCE) can still work without an "active" user.
    if ! gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1; then
      die "no active gcloud account and cannot access project ${PROJECT}. Run: gcloud auth login"
    fi
    say "gcloud: using application-default / metadata credentials"
  else
    say "gcloud account: $active"
  fi

  if ! gcloud projects describe "$PROJECT" --format='value(projectId)' >/dev/null 2>&1; then
    die "cannot describe project '${PROJECT}' — check id, permissions, or: gcloud config set project ${PROJECT}"
  fi
  say "gcloud project access: ok ($PROJECT)"

  # Billing must be linked for Spot compute + budgets.
  local billing_enabled billing_name
  billing_enabled=$(gcloud billing projects describe "$PROJECT" \
    --format='value(billingEnabled)' 2>/dev/null || true)
  billing_name=$(gcloud billing projects describe "$PROJECT" \
    --format='value(billingAccountName)' 2>/dev/null || true)
  if [[ "$billing_enabled" != "True" && "$billing_enabled" != "true" ]]; then
    die "project ${PROJECT} has no billing account linked (Spot is paid). Link billing in the console, then re-run."
  fi
  BILLING_ACCOUNT="${billing_name#billingAccounts/}"
  [[ -n "$BILLING_ACCOUNT" ]] || die "could not resolve billing account for ${PROJECT}"
  say "billing account: $BILLING_ACCOUNT"
}

compare_pr_url() {
  local base="$1" head="$2"
  local origin slug
  origin=$(git -C "$REPO_PATH" config --get remote.origin.url 2>/dev/null || true)
  slug=$(printf '%s' "$origin" | sed -E 's#.*[/:]([^/]+/[^/]+)\.git$#\1#; t; s#.*[/:]([^/]+/[^/]+)$#\1#')
  slug="${slug:-$GITHUB_REPO}"
  printf 'https://github.com/%s/compare/%s...%s?expand=1' "$slug" "$base" "$head"
}

# -------- prereqs (fail fast BEFORE any GCP mutation) --------
ensure_sops
for cmd in gcloud jq curl python3 git sops; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing: $cmd"
done

resolve_repo_path
verify_gcloud_access

# Budget email default from operator git identity (same convention as OCI).
if [[ -z "$BUDGET_EMAIL" ]]; then
  BUDGET_EMAIL=$(git -C "$REPO_PATH" config --get user.email 2>/dev/null \
    || git config --global --get user.email 2>/dev/null \
    || git config --get user.email 2>/dev/null \
    || true)
fi

if [[ -z "$GH_PROFILE" ]]; then
  # Last dash-separated segment of the project id, slugged.
  local_seg="${PROJECT##*-}"
  GH_PROFILE=$(slugify "$local_seg")
  [[ -z "$GH_PROFILE" ]] && GH_PROFILE=$(slugify "$PROJECT")
  [[ -z "$GH_PROFILE" ]] && die "could not derive --gh-profile from project '$PROJECT'"
fi
# Keep filesystem-safe (no path separators).
if [[ "$GH_PROFILE" == *"/"* || "$GH_PROFILE" == *".."* ]]; then
  die "--gh-profile must be a single path segment, got: $GH_PROFILE"
fi
say "inventory account key: $GH_PROFILE"

BRANCH="${BRANCH:-onboard-gcp-${GH_PROFILE}}"
SA_EMAIL="${SA_ID}@${PROJECT}.iam.gserviceaccount.com"

# Token is optional: git push uses operator credentials; PR API is best-effort.
if [[ "$NO_PUSH" != "true" ]] && ! github_token >/dev/null 2>&1; then
  say "no GITHUB_TOKEN/GH_TOKEN — push uses existing git credentials; OPEN URL printed for manual PR"
fi

# =========================================================================
# 1. GCP: enable APIs
# =========================================================================
say "Enabling required APIs on project $PROJECT"
gcloud services enable \
  compute.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  cloudresourcemanager.googleapis.com \
  sts.googleapis.com \
  storage.googleapis.com \
  cloudbilling.googleapis.com \
  billingbudgets.googleapis.com \
  --project="$PROJECT" \
  --quiet

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
[[ -n "$PROJECT_NUMBER" ]] || die "could not resolve project number for $PROJECT"
say "  project number: $PROJECT_NUMBER"

# =========================================================================
# 2. WIF pool + OIDC provider
# =========================================================================
say "Ensuring workload identity pool '$WIF_POOL'"
if gcloud iam workload-identity-pools describe "$WIF_POOL" \
    --project="$PROJECT" --location=global --format='value(name)' >/dev/null 2>&1; then
  say "  pool exists"
else
  gcloud iam workload-identity-pools create "$WIF_POOL" \
    --project="$PROJECT" --location=global \
    --display-name="GitHub" \
    --quiet
  say "  pool created"
fi

say "Ensuring OIDC provider '$WIF_PROVIDER'"
if gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
    --project="$PROJECT" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --format='value(name)' >/dev/null 2>&1; then
  # Only update when out of sync — avoid thrashing a live WIF path that
  # in-flight GitHub Actions jobs depend on for cluster apply.
  cur_issuer=$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
    --project="$PROJECT" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --format='value(oidc.issuerUri)' 2>/dev/null || true)
  cur_cond=$(gcloud iam workload-identity-pools providers describe "$WIF_PROVIDER" \
    --project="$PROJECT" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --format='value(attributeCondition)' 2>/dev/null || true)
  if [[ "$cur_issuer" == "$OIDC_ISSUER" && "$cur_cond" == "$ATTR_CONDITION" ]]; then
    say "  provider exists — issuer/condition already match (no update)"
  else
    say "  provider exists — updating issuer/condition to desired (additive reconcile)"
    gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER" \
      --project="$PROJECT" --location=global \
      --workload-identity-pool="$WIF_POOL" \
      --issuer-uri="$OIDC_ISSUER" \
      --attribute-mapping="$ATTR_MAPPING" \
      --attribute-condition="$ATTR_CONDITION" \
      --quiet
  fi
else
  gcloud iam workload-identity-pools providers create-oidc "$WIF_PROVIDER" \
    --project="$PROJECT" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --display-name="GitHub Actions" \
    --issuer-uri="$OIDC_ISSUER" \
    --attribute-mapping="$ATTR_MAPPING" \
    --attribute-condition="$ATTR_CONDITION" \
    --quiet
  say "  provider created"
fi

WIF_PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/providers/${WIF_PROVIDER}"
say "  provider resource: $WIF_PROVIDER_RESOURCE"

# =========================================================================
# 3. Service account + project roles + WIF binding
# =========================================================================
# CRM IAM can lag a newly-created SA by tens of seconds ("does not exist"
# on add-iam-policy-binding even though describe succeeds). Wait + retry.
wait_for_service_account() {
  local email="$1"
  local max_attempts="${2:-30}"
  local delay="${3:-2}"
  local i
  for ((i = 1; i <= max_attempts; i++)); do
    if gcloud iam service-accounts describe "$email" --project="$PROJECT" \
        --format='value(email)' >/dev/null 2>&1; then
      # Extra settle so Cloud Resource Manager sees the member identity.
      if (( i == 1 )); then
        return 0
      fi
      say "  SA visible after ${i} attempt(s); settling 5s for IAM propagation"
      sleep 5
      return 0
    fi
    say "  waiting for SA ${email} (attempt ${i}/${max_attempts})…"
    sleep "$delay"
  done
  die "service account ${email} not visible after $((max_attempts * delay))s"
}

say "Ensuring service account $SA_EMAIL"
SA_JUST_CREATED="false"
if gcloud iam service-accounts describe "$SA_EMAIL" --project="$PROJECT" \
    --format='value(email)' >/dev/null 2>&1; then
  say "  SA exists"
else
  gcloud iam service-accounts create "$SA_ID" \
    --project="$PROJECT" \
    --display-name="OpenTofu GCP" \
    --description="CI/tofu principal for cluster workers via GitHub WIF" \
    --quiet
  say "  SA created"
  SA_JUST_CREATED="true"
fi
wait_for_service_account "$SA_EMAIL"
if [[ "$SA_JUST_CREATED" == "true" ]]; then
  # Fresh creates almost always need a short CRM propagation pause.
  say "  post-create IAM settle (8s)"
  sleep 8
fi

ensure_project_role() {
  local role="$1"
  local member="serviceAccount:${SA_EMAIL}"
  local attempt max_attempts=12 delay=5
  if gcloud projects get-iam-policy "$PROJECT" \
      --flatten='bindings[].members' \
      --filter="bindings.role=${role} AND bindings.members=${member}" \
      --format='value(bindings.role)' 2>/dev/null | grep -qx "$role"; then
    say "  role $role already bound"
    return 0
  fi
  for ((attempt = 1; attempt <= max_attempts; attempt++)); do
    if gcloud projects add-iam-policy-binding "$PROJECT" \
        --member="$member" \
        --role="$role" \
        --condition=None \
        --quiet >/dev/null 2>/tmp/gcp-iam-bind.err; then
      say "  bound $role"
      return 0
    fi
    # Retry only the classic post-create race; other errors are fatal.
    if grep -qiE 'does not exist|ABORTED|concurrent policy|Please try again' \
        /tmp/gcp-iam-bind.err 2>/dev/null; then
      warn "  bind $role attempt ${attempt}/${max_attempts} raced; retry in ${delay}s"
      sleep "$delay"
      continue
    fi
    cat /tmp/gcp-iam-bind.err >&2 || true
    die "failed to bind $role on project $PROJECT"
  done
  cat /tmp/gcp-iam-bind.err >&2 || true
  die "failed to bind $role after ${max_attempts} attempts (SA IAM still propagating?)"
}

# Least-privilege-ish set for tofu + image import (not full compute.admin):
#   instanceAdmin.v1 — GCE VMs
#   networkAdmin     — VPC / subnet / routes (NOT firewalls — see securityAdmin)
#   securityAdmin    — firewall rules (networkAdmin explicitly excludes them)
#   storageAdmin     — disks + custom images (compute.storageAdmin)
#   storage.objectAdmin — GCS objects (project-level; bucket IAM also set below)
#
# Note: roles/storage.legacyBucketReader is BUCKET-only — it cannot be
# bound on a project (INVALID_ARGUMENT). Bucket describe/get for CI is
# granted via bucket IAM after the staging bucket exists.
for role in \
  roles/compute.instanceAdmin.v1 \
  roles/compute.networkAdmin \
  roles/compute.securityAdmin \
  roles/compute.storageAdmin \
  roles/storage.objectAdmin
do
  ensure_project_role "$role"
done

# Default Compute Engine SA needs actAs so instance create can attach it
# (node-gcp uses the default CE SA when no service_account block is set).
CE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
say "Ensuring actAs on default Compute Engine SA ($CE_SA)"
if gcloud iam service-accounts get-iam-policy "$CE_SA" --project="$PROJECT" \
    --flatten='bindings[].members' \
    --filter="bindings.role=roles/iam.serviceAccountUser AND bindings.members=serviceAccount:${SA_EMAIL}" \
    --format='value(bindings.role)' 2>/dev/null | grep -qx 'roles/iam.serviceAccountUser'; then
  say "  serviceAccountUser already bound on default CE SA"
else
  if gcloud iam service-accounts add-iam-policy-binding "$CE_SA" \
      --project="$PROJECT" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="roles/iam.serviceAccountUser" \
      --quiet >/dev/null 2>/tmp/gcp-ce-sa-bind.err; then
    say "  bound roles/iam.serviceAccountUser → $CE_SA"
  else
    # Some projects disable the default CE SA until first use; non-fatal
    # if compute will create it later — surface the error clearly.
    warn "could not bind serviceAccountUser on $CE_SA: $(head -c 200 /tmp/gcp-ce-sa-bind.err 2>/dev/null || true)"
    warn "VM create may fail until: gcloud iam service-accounts add-iam-policy-binding $CE_SA --member=serviceAccount:${SA_EMAIL} --role=roles/iam.serviceAccountUser --project=$PROJECT"
  fi
fi

# Pre-create the image-staging bucket so CI never needs storage.buckets.create.
# Object writes: project objectAdmin + bucket objectAdmin.
# Bucket describe (gcloud storage buckets describe): bucket legacyBucketReader
# only (that role is invalid at project scope).
IMAGE_BUCKET="stawi-talos-images-${GH_PROFILE}"
say "Ensuring image staging bucket gs://${IMAGE_BUCKET}"
if gcloud storage buckets describe "gs://${IMAGE_BUCKET}" --project="$PROJECT" >/dev/null 2>&1; then
  say "  bucket exists"
else
  if gcloud storage buckets create "gs://${IMAGE_BUCKET}" \
      --project="$PROJECT" \
      --location="$REGION" \
      --uniform-bucket-level-access \
      --default-storage-class=STANDARD \
      --quiet 2>/tmp/gcs-boot-create.err; then
    say "  bucket created"
  else
    die "could not create gs://${IMAGE_BUCKET}: $(head -c 400 /tmp/gcs-boot-create.err 2>/dev/null || true)"
  fi
fi

tmp_lc=$(mktemp)
cat >"$tmp_lc" <<'JSON'
{
  "rule": [
    {
      "action": { "type": "Delete" },
      "condition": { "age": 30, "matchesPrefix": [] }
    }
  ]
}
JSON
gcloud storage buckets update "gs://${IMAGE_BUCKET}" \
  --project="$PROJECT" \
  --lifecycle-file="$tmp_lc" \
  --quiet >/dev/null 2>&1 \
  && say "  lifecycle: delete objects after 30d" \
  || warn "could not set lifecycle on gs://${IMAGE_BUCKET} (non-fatal)"
rm -f "$tmp_lc"

# Bucket-scoped IAM — required for CI under uniform bucket-level access.
# legacyBucketReader MUST be on the bucket resource (not the project).
ensure_bucket_role() {
  local b_role="$1"
  if gcloud storage buckets get-iam-policy "gs://${IMAGE_BUCKET}" --project="$PROJECT" \
      --flatten='bindings[].members' \
      --filter="bindings.role=${b_role} AND bindings.members:serviceAccount:${SA_EMAIL}" \
      --format='value(bindings.role)' 2>/dev/null | grep -qx "$b_role"; then
    say "  bucket IAM $b_role already bound"
    return 0
  fi
  if gcloud storage buckets add-iam-policy-binding "gs://${IMAGE_BUCKET}" \
      --member="serviceAccount:${SA_EMAIL}" \
      --role="$b_role" \
      --project="$PROJECT" \
      --quiet >/dev/null 2>/tmp/gcs-bucket-iam.err; then
    say "  bucket IAM bound $b_role"
    return 0
  fi
  cat /tmp/gcs-bucket-iam.err >&2 || true
  die "failed to bind $b_role on gs://${IMAGE_BUCKET}"
}

for b_role in roles/storage.objectAdmin roles/storage.legacyBucketReader; do
  ensure_bucket_role "$b_role"
done

WIF_MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}"
say "Ensuring WIF principal binding on SA"
if gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project="$PROJECT" \
    --flatten='bindings[].members' \
    --filter="bindings.role=roles/iam.workloadIdentityUser AND bindings.members=${WIF_MEMBER}" \
    --format='value(bindings.role)' 2>/dev/null | grep -qx 'roles/iam.workloadIdentityUser'; then
  say "  workloadIdentityUser already bound for ${GITHUB_REPO}"
else
  wif_ok="false"
  for ((attempt = 1; attempt <= 8; attempt++)); do
    if gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
        --project="$PROJECT" \
        --role="roles/iam.workloadIdentityUser" \
        --member="$WIF_MEMBER" \
        --quiet >/dev/null 2>/tmp/gcp-wif-bind.err; then
      say "  bound roles/iam.workloadIdentityUser → $WIF_MEMBER"
      wif_ok="true"
      break
    fi
    warn "  WIF bind attempt ${attempt}/8 failed; retry in 5s"
    sleep 5
  done
  if [[ "$wif_ok" != "true" ]]; then
    cat /tmp/gcp-wif-bind.err >&2 || true
    die "failed to bind workloadIdentityUser on $SA_EMAIL"
  fi
fi

# =========================================================================
# 4. Cloud Billing budget (cost tripwire)
# =========================================================================
# Mirrors OCI's budget step: monthly cap + threshold ladder. Not a hard
# provisioner stop — alerts billing-account admins (and console).
BUDGET_ID=""
if [[ "$NO_BUDGET" == "true" ]]; then
  say "skipping Cloud Billing budget (--no-budget)"
else
  say "Ensuring budget '$BUDGET_NAME' (USD ${BUDGET_AMOUNT}/month, project ${PROJECT})"
  if [[ -n "$BUDGET_EMAIL" ]]; then
    say "  budget-email hint: ${BUDGET_EMAIL} (GCP emails Billing Account Admin/User by default)"
  fi

  existing_budget_json=$(gcloud billing budgets list \
    --billing-account="$BILLING_ACCOUNT" \
    --format=json 2>/dev/null || echo '[]')
  if ! printf '%s' "$existing_budget_json" | jq empty 2>/dev/null; then
    warn "  budget list returned non-JSON; treating as empty"
    existing_budget_json='[]'
  fi

  BUDGET_ID=$(printf '%s' "$existing_budget_json" | jq -r \
    --arg n "$BUDGET_NAME" \
    '.[] | select(.displayName == $n) | .name // empty' | head -1)

  # Threshold ladder: current-spend 50/80/100 + forecasted 50/100.
  # gcloud --threshold-rule uses fraction (0.5 = 50%).
  THRESHOLD_ARGS=(
    --threshold-rule=percent=0.50
    --threshold-rule=percent=0.80
    --threshold-rule=percent=1.00
    --threshold-rule=percent=0.50,basis=forecasted-spend
    --threshold-rule=percent=1.00,basis=forecasted-spend
  )

  if [[ -z "$BUDGET_ID" ]]; then
    say "  creating budget"
    if create_out=$(gcloud billing budgets create \
        --billing-account="$BILLING_ACCOUNT" \
        --display-name="$BUDGET_NAME" \
        --budget-amount="${BUDGET_AMOUNT}USD" \
        --filter-projects="projects/${PROJECT}" \
        --calendar-period=month \
        "${THRESHOLD_ARGS[@]}" \
        --format='value(name)' 2>&1); then
      BUDGET_ID=$(printf '%s' "$create_out" | tail -1)
      say "  budget created: $BUDGET_ID"
    else
      warn "  budget create failed (billing.budgets admin on the billing account?):"
      printf '%s\n' "$create_out" | head -c 800 >&2
      printf '\n' >&2
      warn "  continuing — WIF/auth still valid; set budget in console if needed"
    fi
  else
    say "  exists ($BUDGET_ID); reconciling amount + thresholds"
    if gcloud billing budgets update "$BUDGET_ID" \
        --billing-account="$BILLING_ACCOUNT" \
        --budget-amount="${BUDGET_AMOUNT}USD" \
        --filter-projects="projects/${PROJECT}" \
        "${THRESHOLD_ARGS[@]}" \
        --quiet >/dev/null 2>&1; then
      say "  budget updated"
    else
      warn "  budget update returned non-zero (often ok — partial field immutability)"
    fi
  fi
  [[ -n "$BUDGET_ID" ]] && say "  budget: $BUDGET_ID (USD ${BUDGET_AMOUNT}/mo)"
fi

# =========================================================================
# 5. Repo write phase (isolated worktree) — skipped when already onboarded
# =========================================================================
# Cluster safety: re-running bootstrap on a project that already has auth
# on origin/<base> must not rewrite accounts.yaml (that retriggers
# onboard-gcp → full cluster-provision). IAM ensure above is enough.

say ""
say "=========================================================="
say "GCP WIF ready for project [$PROJECT]."
say "  SAFETY: no GCE VMs/disks/VPCs/firewalls were created, stopped, or deleted."

already_onboarded="false"
if git -C "$REPO_PATH" rev-parse --verify "origin/${BASE_BRANCH}" >/dev/null 2>&1 \
    || git -C "$REPO_PATH" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null; then
  if git -C "$REPO_PATH" cat-file -e "origin/${BASE_BRANCH}:tofu/shared/accounts/gcp/${GH_PROFILE}/auth.yaml" 2>/dev/null; then
    if git -C "$REPO_PATH" show "origin/${BASE_BRANCH}:tofu/shared/accounts.yaml" 2>/dev/null \
        | grep -qE "^[[:space:]]*-[[:space:]]+${GH_PROFILE}[[:space:]]*\$"; then
      already_onboarded="true"
    fi
  fi
elif git -C "$REPO_PATH" rev-parse --verify "refs/heads/${BASE_BRANCH}" >/dev/null 2>&1; then
  if git -C "$REPO_PATH" cat-file -e "${BASE_BRANCH}:tofu/shared/accounts/gcp/${GH_PROFILE}/auth.yaml" 2>/dev/null; then
    if git -C "$REPO_PATH" show "${BASE_BRANCH}:tofu/shared/accounts.yaml" 2>/dev/null \
        | grep -qE "^[[:space:]]*-[[:space:]]+${GH_PROFILE}[[:space:]]*\$"; then
      already_onboarded="true"
    fi
  fi
fi

SKIP_REPO_WRITE="false"
if [[ "$IAM_ONLY" == "true" ]]; then
  SKIP_REPO_WRITE="true"
  say "skipping git/PR path (--iam-only)"
elif [[ "$already_onboarded" == "true" && "$FORCE_REPO_WRITE" != "true" ]]; then
  SKIP_REPO_WRITE="true"
  say "account '${GH_PROFILE}' already on ${BASE_BRANCH} — IAM ensure only (no repo write)."
  say "  This avoids re-triggering onboard-gcp / cluster-provision. Use --force-repo-write to rewrite auth."
fi

if [[ "$SKIP_REPO_WRITE" == "true" ]]; then
  say ""
  say "Done (cluster-safe re-run)."
  say "  project:  $PROJECT ($PROJECT_NUMBER)"
  say "  SA:       $SA_EMAIL"
  say "  WIF:      $WIF_PROVIDER_RESOURCE"
  say "  account:  $GH_PROFILE"
  say "  region:   $REGION"
  [[ -n "${BUDGET_ID:-}" ]] && say "  budget:   $BUDGET_ID (USD ${BUDGET_AMOUNT}/mo → $BUDGET_NAME)"
  say "  compute:  NOT modified (bootstrap never touches VMs/disks/VPC)"
  exit 0
fi

say "Writing auth + accounts.yaml on branch $BRANCH (base $BASE_BRANCH)"

WORKTREE=""
cleanup_worktree() {
  if [[ -n "${WORKTREE:-}" && -d "${WORKTREE:-}" ]]; then
    git -C "$REPO_PATH" worktree remove --force "$WORKTREE" 2>/dev/null \
      || rm -rf "$WORKTREE"
  fi
}
trap cleanup_worktree EXIT

# Resolve base ref: prefer origin/<base>, fall back to local.
BASE_REF=""
if git -C "$REPO_PATH" fetch origin "$BASE_BRANCH" --quiet 2>/dev/null; then
  BASE_REF="origin/${BASE_BRANCH}"
elif git -C "$REPO_PATH" rev-parse --verify "origin/${BASE_BRANCH}" >/dev/null 2>&1; then
  BASE_REF="origin/${BASE_BRANCH}"
  warn "could not fetch origin/${BASE_BRANCH}; using cached remote-tracking ref"
elif git -C "$REPO_PATH" rev-parse --verify "refs/heads/${BASE_BRANCH}" >/dev/null 2>&1; then
  BASE_REF="$BASE_BRANCH"
  warn "could not fetch origin/${BASE_BRANCH}; using local ${BASE_BRANCH}"
else
  die "cannot resolve base branch '${BASE_BRANCH}' (fetch failed and no local/remote ref)"
fi

# Best-effort fetch of existing push branch so we can reuse it.
git -C "$REPO_PATH" fetch origin "$BRANCH" --quiet 2>/dev/null || true

WORKTREE=$(mktemp -d -t "onboard-gcp-${GH_PROFILE}.XXXXXX")

if git -C "$REPO_PATH" rev-parse --verify "origin/${BRANCH}" >/dev/null 2>&1; then
  say "  reusing existing origin/${BRANCH}"
  git -C "$REPO_PATH" worktree add -B "$BRANCH" "$WORKTREE" "origin/${BRANCH}"
elif git -C "$REPO_PATH" rev-parse --verify "refs/heads/${BRANCH}" >/dev/null 2>&1; then
  say "  reusing local ${BRANCH}"
  git -C "$REPO_PATH" worktree add -f -B "$BRANCH" "$WORKTREE" "$BRANCH"
else
  say "  creating ${BRANCH} from ${BASE_REF}"
  git -C "$REPO_PATH" worktree add -B "$BRANCH" "$WORKTREE" "$BASE_REF"
fi

AUTH_DIR="$WORKTREE/tofu/shared/accounts/gcp/$GH_PROFILE"
AUTH_FILE="$AUTH_DIR/auth.yaml"
ACCOUNTS_FILE="$WORKTREE/tofu/shared/accounts.yaml"
mkdir -p "$AUTH_DIR"

# Preserve existing encrypted auth when values already match (needs decrypt
# key). Without a private key we still rewrite only for first onboard /
# --force-repo-write (already gated above).
desired_plain=$(cat <<EOF
auth:
  project_id: "${PROJECT}"
  region: "${REGION}"
  vpc_cidr: "${VPC_CIDR}"
  workload_identity_provider: "${WIF_PROVIDER_RESOURCE}"
  service_account_email: "${SA_EMAIL}"
EOF
)
write_auth="true"
if [[ -f "$AUTH_FILE" ]] && grep -q '^sops:' "$AUTH_FILE" 2>/dev/null; then
  if decrypted=$(sops -d --input-type yaml --output-type yaml "$AUTH_FILE" 2>/dev/null); then
    # Normalize whitespace for compare
    if [[ "$(printf '%s\n' "$decrypted" | sed '/^$/d')" == "$(printf '%s\n' "$desired_plain" | sed '/^$/d')" ]]; then
      say "existing auth.yaml already matches desired fields — keeping ciphertext"
      write_auth="false"
    else
      say "existing auth.yaml differs — re-encrypting with new values"
    fi
  fi
fi

if [[ "$write_auth" == "true" ]]; then
  printf '%s\n' "$desired_plain" > "$AUTH_FILE"
  # Encrypt in place; .sops.yaml at worktree root is checked out from base.
  if ! (cd "$WORKTREE" && sops -e --input-type yaml --output-type yaml -i \
    "tofu/shared/accounts/gcp/${GH_PROFILE}/auth.yaml"); then
    die "sops encrypt failed — check .sops.yaml age recipients and sops version"
  fi
  if ! grep -q '^sops:' "$AUTH_FILE"; then
    die "auth.yaml does not look SOPS-encrypted after sops -e (missing sops: key)"
  fi
  say "wrote encrypted $AUTH_FILE"
fi

# Idempotent accounts.yaml edit under gcp:
if ! grep -qE "^[[:space:]]*-[[:space:]]+${GH_PROFILE}[[:space:]]*\$" "$ACCOUNTS_FILE"; then
  python3 - "$ACCOUNTS_FILE" "$GH_PROFILE" <<'PY'
import re
import sys

path, name = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
out = []
in_gcp = False
inserted = False
gcp_seen = False

for line in lines:
    # gcp: []  → expand to a real list with this account
    if re.match(r"^gcp:\s*\[\s*\]\s*$", line):
        out.append("gcp:")
        out.append(f"  - {name}")
        inserted = True
        gcp_seen = True
        in_gcp = False
        continue
    if re.match(r"^gcp:\s*$", line):
        in_gcp = True
        gcp_seen = True
        out.append(line)
        continue
    if in_gcp and not inserted:
        # Still inside gcp list block
        if line.startswith("  -") or line.startswith("  #") or line.strip() == "":
            out.append(line)
            continue
        # Left the gcp block (next top-level key)
        out.append(f"  - {name}")
        inserted = True
        in_gcp = False
        out.append(line)
        continue
    out.append(line)

if gcp_seen and not inserted:
    out.append(f"  - {name}")
    inserted = True
elif not gcp_seen:
    out.append("gcp:")
    out.append(f"  - {name}")
    inserted = True

open(path, "w").write("\n".join(out) + "\n")
if not inserted:
    sys.exit("failed to insert account into gcp: list")
PY
  say "added '$GH_PROFILE' to gcp: in tofu/shared/accounts.yaml"
else
  say "'$GH_PROFILE' already in accounts.yaml — skipping edit"
fi

# Commit only when there is a diff (idempotent re-run).
cd "$WORKTREE"
git add \
  "tofu/shared/accounts/gcp/${GH_PROFILE}/auth.yaml" \
  "tofu/shared/accounts.yaml"

if git diff --cached --quiet; then
  say "no changes to commit (auth + accounts already match)"
else
  # Prefer operator identity; fall back so non-interactive envs still work.
  if ! git config user.email >/dev/null 2>&1; then
    git config user.email "${GIT_AUTHOR_EMAIL:-bootstrap-gcp-wif@stawi.org}"
  fi
  if ! git config user.name >/dev/null 2>&1; then
    git config user.name "${GIT_AUTHOR_NAME:-bootstrap-gcp-wif}"
  fi
  git commit -m "onboard gcp ${GH_PROFILE}: add to accounts.yaml + encrypted auth"
  say "committed on $BRANCH"
fi

OPEN_URL=$(compare_pr_url "$BASE_BRANCH" "$BRANCH")
PR_HEAD="$BRANCH"   # may become "user:branch" when pushing via fork
PUSH_OK="false"
TOKEN=""
TOKEN=$(github_token 2>/dev/null || true)

pr_body_text() {
  cat <<EOF
## Onboard GCP account \`${GH_PROFILE}\`

Adds SOPS-encrypted WIF auth and registers the account under \`gcp:\` in \`accounts.yaml\`.

| Field | Value |
|---|---|
| project_id | \`${PROJECT}\` |
| region | \`${REGION}\` |
| vpc_cidr | \`${VPC_CIDR}\` |
| service_account | \`${SA_EMAIL}\` |
| workload_identity_provider | \`${WIF_PROVIDER_RESOURCE}\` |
| monthly budget | USD \`${BUDGET_AMOUNT}\` (\`${BUDGET_NAME}\`) |

After merge, \`onboard-gcp\` runs \`cluster-provision\` (mode=full, no wipe).
OpenTofu seeds default Spot capacity (2×e2-standard-2 / 8 GiB) when inventory is empty.
EOF
}

print_token_help() {
  cat >&2 <<EOF

GCP side is complete (WIF, SA, roles, bucket, budget). Git push was skipped
because this run is non-interactive and no GitHub credentials were available.

To finish (push branch + open PR), set a token and re-run the same command:

  export GITHUB_TOKEN=ghp_xxxxxxxx   # classic PAT: repo scope
  # or fine-grained: Contents (R/W) + Pull requests on ${GITHUB_REPO}
  ./bootstrap-gcp-wif.sh --project ${PROJECT} --gh-profile ${GH_PROFILE} --region ${REGION}

Local branch kept at: ${REPO_PATH}  (${BRANCH})

EOF
}

if [[ "$NO_PUSH" = "true" ]]; then
  say "branch '$BRANCH' ready locally — skipping push (--no-push)"
  say "  (worktree will be removed; branch ref remains in $REPO_PATH)"
  say "OPEN: $OPEN_URL  (after you push)"
else
  REFSPEC="HEAD:refs/heads/${BRANCH}"
  ORIGIN_URL="https://github.com/${GITHUB_REPO}.git"

  if [[ -n "$TOKEN" ]]; then
    # Token-first: never use interactive credential prompts.
    say "pushing with GitHub token (non-interactive)"
    token_url="https://x-access-token:${TOKEN}@github.com/${GITHUB_REPO}.git"
    if git_push_noninteractive "$token_url" "$REFSPEC"; then
      PUSH_OK="true"
      say "pushed origin/${BRANCH}"
    else
      warn "push to ${GITHUB_REPO} failed (no write access or token scope?)"
      head -c 400 /tmp/gcp-git-push.err >&2 || true
      printf '\n' >&2
      # Fork + push + cross-repo PR (contributor without upstream write).
      if fork_full=$(github_ensure_fork "$TOKEN"); then
        fork_url="https://x-access-token:${TOKEN}@github.com/${fork_full}.git"
        say "pushing to fork ${fork_full}"
        if git_push_noninteractive "$fork_url" "$REFSPEC"; then
          PUSH_OK="true"
          PR_HEAD="${fork_full%%/*}:${BRANCH}"
          OPEN_URL="https://github.com/${GITHUB_REPO}/compare/${BASE_BRANCH}...${PR_HEAD}?expand=1"
          say "pushed ${fork_full}/${BRANCH}"
        else
          warn "fork push failed:"
          head -c 400 /tmp/gcp-git-push.err >&2 || true
          printf '\n' >&2
        fi
      fi
    fi
  else
    # No token: one non-interactive attempt (SSH key / cached helper only).
    say "no GITHUB_TOKEN/GH_TOKEN/gh — attempting non-interactive git push"
    if git_push_noninteractive "$ORIGIN_URL" "$REFSPEC" \
        || git_push_noninteractive "origin" "$REFSPEC"; then
      PUSH_OK="true"
      say "pushed origin/${BRANCH}"
    else
      warn "git push failed without credentials (non-interactive; will not prompt)"
      head -c 200 /tmp/gcp-git-push.err >&2 || true
      printf '\n' >&2
    fi
  fi

  if [[ "$PUSH_OK" != "true" ]]; then
    print_token_help
    say "Done (GCP only)."
    say "  project:  $PROJECT ($PROJECT_NUMBER)"
    say "  SA:       $SA_EMAIL"
    say "  WIF:      $WIF_PROVIDER_RESOURCE"
    say "  account:  $GH_PROFILE"
    say "  branch:   $BRANCH (local only — not on GitHub yet)"
    say "  region:   $REGION"
    [[ -n "$BUDGET_ID" ]] && say "  budget:   $BUDGET_ID (USD ${BUDGET_AMOUNT}/mo → $BUDGET_NAME)"
    say "  compute:  NOT modified (bootstrap never touches VMs/disks/VPC)"
    # Exit 0: GCP bootstrap succeeded; git is a follow-up with a token.
    exit 0
  fi

  if [[ "$NO_PR" = "true" ]]; then
    say "skipping PR API (--no-pr)"
    say "OPEN: $OPEN_URL"
  elif [[ -z "$TOKEN" ]]; then
    say "pushed without token — open the PR in the browser:"
    say "OPEN: $OPEN_URL"
  else
    if pr_url=$(github_create_pr \
      "onboard gcp ${GH_PROFILE}" \
      "$PR_HEAD" \
      "$BASE_BRANCH" \
      "$(pr_body_text)"); then
      [[ -n "$pr_url" ]] && OPEN_URL="$pr_url"
    else
      warn "PR API failed — open manually"
    fi
    say "OPEN: $OPEN_URL"
  fi
fi

say ""
say "Done."
say "  project:  $PROJECT ($PROJECT_NUMBER)"
say "  SA:       $SA_EMAIL"
say "  WIF:      $WIF_PROVIDER_RESOURCE"
say "  account:  $GH_PROFILE"
say "  branch:   $BRANCH"
say "  region:   $REGION"
[[ -n "$BUDGET_ID" ]] && say "  budget:   $BUDGET_ID (USD ${BUDGET_AMOUNT}/mo → $BUDGET_NAME)"
say "  OPEN:     $OPEN_URL"
say "  compute:  NOT modified (bootstrap never touches VMs/disks/VPC/firewalls)"
