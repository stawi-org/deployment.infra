#!/usr/bin/env bash
# scripts/bootstrap-gcp-wif.sh
#
# Idempotently configure GCP Workload Identity Federation for GitHub Actions
# OIDC, then open a PR that lands the encrypted auth + accounts.yaml entry.
#
#   GitHub JWT  →  WIF pool/provider (github / github-actions)
#                       ↓ attribute.repository == stawi-org/deployment.infra
#                  SA tofu-gcp@PROJECT  (roles/iam.workloadIdentityUser)
#                       ↓ impersonation
#                  OpenTofu / image-import ADC in CI
#
# Prereqs:
#   - gcloud CLI installed and authed to the target project (Owner or
#     equivalent for IAM + service usage)
#   - jq, curl, python3, git
#   - sops (auto-installed into ~/.local/bin if missing)
#   - GITHUB_TOKEN or GH_TOKEN with Contents + Pull requests on
#     stawi-org/deployment.infra (for push + PR; optional with --no-push/--no-pr)
#   - A local clone of deployment.infra with .sops.yaml at the root
#
# Each invocation:
#   1. Enables required APIs; ensures WIF pool, OIDC provider, SA, project
#      IAM roles, and WIF→SA binding.
#   2. Writes a SOPS-encrypted auth.yaml under
#      tofu/shared/accounts/gcp/<gh-profile>/ in a git worktree off
#      origin/<base-branch> so the operator's current branch stays clean.
#   3. Adds the account under gcp: in tofu/shared/accounts.yaml (idempotent).
#   4. Commits, pushes branch onboard-gcp-<gh-profile>, opens a PR via the
#      GitHub REST API (no gh CLI required).
#
# Usage:
#   ./scripts/bootstrap-gcp-wif.sh --project YOUR_PROJECT_ID
#   ./scripts/bootstrap-gcp-wif.sh --project p --gh-profile demo --region europe-west9
#   ./scripts/bootstrap-gcp-wif.sh --project p --no-push   # local branch only
#
# Re-running is safe. GCP resources are looked up by name; missing ones are
# created and existing ones updated. The accounts.yaml edit is idempotent.
# The branch is reused if it already exists.

set -euo pipefail

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

WIF_POOL="github"
WIF_PROVIDER="github-actions"
SA_ID="tofu-gcp"
GITHUB_REPO="stawi-org/deployment.infra"
OIDC_ISSUER="https://token.actions.githubusercontent.com"
ATTR_CONDITION="assertion.repository=='${GITHUB_REPO}'"
ATTR_MAPPING="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref"

SOPS_VERSION="v3.11.0"

usage() {
  # Emit the leading comment block (strip "# " prefix) then the flag table.
  awk 'NR==1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' \
    "${BASH_SOURCE[0]}"
  cat <<'EOF'

Flags:
  --project <ID>       GCP project id (required)
  --region <REGION>    Default europe-west9 (Paris FR; nearest to Marseille)
  --gh-profile <NAME>  accounts.yaml key / auth path segment
                       (default: slug of project id last dash segment)
  --vpc-cidr <CIDR>    Default 10.210.0.0/24
  --repo-path <PATH>   deployment.infra checkout (default: git root)
  --base-branch <NAME> Branch to fork the worktree from (default: main)
  --branch <NAME>      Push branch (default: onboard-gcp-<gh-profile>)
  --no-push            Commit in worktree only; skip push
  --no-pr              Push but do not open a pull request
  -h, --help           Show this help
EOF
  exit 1
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --project)     PROJECT="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --gh-profile)  GH_PROFILE="$2"; shift 2 ;;
    --vpc-cidr)    VPC_CIDR="$2"; shift 2 ;;
    --repo-path)   REPO_PATH="$2"; shift 2 ;;
    --base-branch) BASE_BRANCH="$2"; shift 2 ;;
    --branch)      BRANCH="$2"; shift 2 ;;
    --no-push)     NO_PUSH="true"; shift ;;
    --no-pr)       NO_PR="true"; shift ;;
    -h|--help)     usage ;;
    *)             echo "unknown arg: $1" >&2; usage ;;
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
  if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    printf '%s' "$GITHUB_TOKEN"
    return 0
  fi
  if [[ -n "${GH_TOKEN:-}" ]]; then
    printf '%s' "$GH_TOKEN"
    return 0
  fi
  return 1
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
    local existing
    existing=$(github_api GET \
      "/repos/${GITHUB_REPO}/pulls?head=${GITHUB_REPO%%/*}:${head}&state=open" \
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

# -------- prereqs --------
ensure_sops
for cmd in gcloud jq curl python3 git sops; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing: $cmd"
done

if [[ -z "$REPO_PATH" ]]; then
  REPO_PATH=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [[ -z "$REPO_PATH" ]] && die "Not inside a git repo; pass --repo-path PATH explicitly"
fi
REPO_PATH="$(cd "$REPO_PATH" && pwd)"
[[ -f "$REPO_PATH/.sops.yaml" ]] \
  || die "$REPO_PATH has no .sops.yaml — wrong checkout? Aborting before any write."
say "repo path: $REPO_PATH"

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

# Warn early when push/PR will lack a token (push can still use git creds).
if [[ "$NO_PUSH" != "true" ]] && ! github_token >/dev/null 2>&1; then
  warn "no GITHUB_TOKEN/GH_TOKEN — push will use existing git credentials; PR open needs a token"
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
  say "  provider exists — reconciling attribute mapping/condition"
  gcloud iam workload-identity-pools providers update-oidc "$WIF_PROVIDER" \
    --project="$PROJECT" --location=global \
    --workload-identity-pool="$WIF_POOL" \
    --issuer-uri="$OIDC_ISSUER" \
    --attribute-mapping="$ATTR_MAPPING" \
    --attribute-condition="$ATTR_CONDITION" \
    --quiet
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
say "Ensuring service account $SA_EMAIL"
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
fi

ensure_project_role() {
  local role="$1"
  local member="serviceAccount:${SA_EMAIL}"
  if gcloud projects get-iam-policy "$PROJECT" \
      --flatten='bindings[].members' \
      --filter="bindings.role=${role} AND bindings.members=${member}" \
      --format='value(bindings.role)' 2>/dev/null | grep -qx "$role"; then
    say "  role $role already bound"
    return 0
  fi
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="$member" \
    --role="$role" \
    --condition=None \
    --quiet >/dev/null
  say "  bound $role"
}

# Least-privilege-ish set for tofu + image import (not full compute.admin):
#   instanceAdmin.v1 — GCE VMs
#   networkAdmin     — VPC / subnet / firewall
#   storageAdmin     — disks + custom images (compute.storageAdmin)
#   storage.objectAdmin — GCS objects for image staging (bucket is
#                         created once below so we do not need storage.admin)
for role in \
  roles/compute.instanceAdmin.v1 \
  roles/compute.networkAdmin \
  roles/compute.storageAdmin \
  roles/storage.objectAdmin
do
  ensure_project_role "$role"
done

# Pre-create the image-staging bucket so CI never needs storage.admin
# (bucket create). Object writes use objectAdmin above. Nearline + 30d
# lifecycle keeps staged .raw.tar.gz from accumulating forever.
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
    warn "could not create gs://${IMAGE_BUCKET}: $(head -c 200 /tmp/gcs-boot-create.err 2>/dev/null || true)"
    warn "CI may fail image import until the bucket exists or a fallback name works"
  fi
fi
# Lifecycle: drop objects older than 30 days (image imports re-upload
# when schematic/sha changes; stale staging bytes are pure waste).
if gcloud storage buckets describe "gs://${IMAGE_BUCKET}" --project="$PROJECT" >/dev/null 2>&1; then
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
fi

WIF_MEMBER="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${WIF_POOL}/attribute.repository/${GITHUB_REPO}"
say "Ensuring WIF principal binding on SA"
if gcloud iam service-accounts get-iam-policy "$SA_EMAIL" --project="$PROJECT" \
    --flatten='bindings[].members' \
    --filter="bindings.role=roles/iam.workloadIdentityUser AND bindings.members=${WIF_MEMBER}" \
    --format='value(bindings.role)' 2>/dev/null | grep -qx 'roles/iam.workloadIdentityUser'; then
  say "  workloadIdentityUser already bound for ${GITHUB_REPO}"
else
  gcloud iam service-accounts add-iam-policy-binding "$SA_EMAIL" \
    --project="$PROJECT" \
    --role="roles/iam.workloadIdentityUser" \
    --member="$WIF_MEMBER" \
    --quiet >/dev/null
  say "  bound roles/iam.workloadIdentityUser → $WIF_MEMBER"
fi

# =========================================================================
# 4. Repo write phase (isolated worktree)
# =========================================================================
say ""
say "=========================================================="
say "GCP WIF ready for project [$PROJECT]."
say "Writing auth + accounts.yaml on branch $BRANCH (base $BASE_BRANCH)"

WORKTREE=""
cleanup_worktree() {
  if [[ -n "${WORKTREE:-}" && -d "${WORKTREE:-}" ]]; then
    git -C "$REPO_PATH" worktree remove --force "$WORKTREE" 2>/dev/null \
      || rm -rf "$WORKTREE"
  fi
}
trap cleanup_worktree EXIT

git -C "$REPO_PATH" fetch origin "$BASE_BRANCH" --quiet
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
  say "  creating ${BRANCH} from origin/${BASE_BRANCH}"
  git -C "$REPO_PATH" worktree add -B "$BRANCH" "$WORKTREE" "origin/${BASE_BRANCH}"
fi

AUTH_DIR="$WORKTREE/tofu/shared/accounts/gcp/$GH_PROFILE"
AUTH_FILE="$AUTH_DIR/auth.yaml"
ACCOUNTS_FILE="$WORKTREE/tofu/shared/accounts.yaml"
mkdir -p "$AUTH_DIR"

cat > "$AUTH_FILE" <<EOF
auth:
  project_id: "${PROJECT}"
  region: "${REGION}"
  vpc_cidr: "${VPC_CIDR}"
  workload_identity_provider: "${WIF_PROVIDER_RESOURCE}"
  service_account_email: "${SA_EMAIL}"
EOF

# Encrypt in place; .sops.yaml at worktree root is checked out from base.
(cd "$WORKTREE" && sops -e --input-type yaml --output-type yaml -i \
  "tofu/shared/accounts/gcp/${GH_PROFILE}/auth.yaml")
say "wrote encrypted $AUTH_FILE"

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

if [[ "$NO_PUSH" = "true" ]]; then
  say "branch '$BRANCH' ready locally at $WORKTREE — skipping push (--no-push)"
  say "  (worktree will be removed; branch ref remains in $REPO_PATH)"
else
  push_url=""
  if token=$(github_token 2>/dev/null); then
    push_url="https://x-access-token:${token}@github.com/${GITHUB_REPO}.git"
  fi
  if [[ -n "$push_url" ]]; then
    git push "$push_url" "HEAD:refs/heads/${BRANCH}" --force-with-lease
  else
    git push -u origin "HEAD:refs/heads/${BRANCH}"
  fi
  say "pushed origin/${BRANCH}"

  if [[ "$NO_PR" = "true" ]]; then
    say "skipping PR (--no-pr)"
    origin=$(git -C "$REPO_PATH" config --get remote.origin.url || true)
    slug=$(printf '%s' "$origin" | sed -E 's#.*[/:]([^/]+/[^/]+)\.git$#\1#; t; s#.*[/:]([^/]+/[^/]+)$#\1#')
    slug="${slug:-$GITHUB_REPO}"
    say "OPEN: https://github.com/${slug}/compare/${BASE_BRANCH}...${BRANCH}?expand=1"
  else
    if ! github_token >/dev/null 2>&1; then
      warn "no GITHUB_TOKEN/GH_TOKEN — cannot open PR via API"
      say "OPEN: https://github.com/${GITHUB_REPO}/compare/${BASE_BRANCH}...${BRANCH}?expand=1"
    else
      pr_body=$(cat <<EOF
## Onboard GCP account \`${GH_PROFILE}\`

Adds SOPS-encrypted WIF auth and registers the account under \`gcp:\` in \`accounts.yaml\`.

| Field | Value |
|---|---|
| project_id | \`${PROJECT}\` |
| region | \`${REGION}\` |
| vpc_cidr | \`${VPC_CIDR}\` |
| service_account | \`${SA_EMAIL}\` |
| workload_identity_provider | \`${WIF_PROVIDER_RESOURCE}\` |

After merge, \`onboard-gcp\` runs \`cluster-provision\` (mode=full, no wipe).
OpenTofu seeds default Spot capacity (2×e2-standard-2 / 8 GiB) when inventory is empty.
EOF
)
      github_create_pr \
        "onboard gcp ${GH_PROFILE}" \
        "$BRANCH" \
        "$BASE_BRANCH" \
        "$pr_body" || true
    fi
  fi
fi

say ""
say "Done."
say "  project:  $PROJECT ($PROJECT_NUMBER)"
say "  SA:       $SA_EMAIL"
say "  WIF:      $WIF_PROVIDER_RESOURCE"
say "  account:  $GH_PROFILE"
say "  branch:   $BRANCH"
