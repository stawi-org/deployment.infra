#!/usr/bin/env bash
# scripts/get-kubeconfig.sh
#
# Convenience wrapper around the dispatch-kubeconfig GitHub Actions workflow.
# Dispatches the workflow, waits for it to finish, downloads the encrypted
# artifact, decrypts it with your SSH private key, installs it at
# ~/.kube/config (or wherever you point $KUBECONFIG), and prints cluster
# status so you know it worked.
#
# Requirements locally:
#   - gh CLI (authed against antinvestor/deployments)
#   - age (https://github.com/FiloSottile/age — `brew install age` / `apt install age`)
#   - an ssh-ed25519 or ssh-rsa private key (defaults to ~/.ssh/id_ed25519)
#   - a matching public key added at https://github.com/settings/keys
#     (the workflow encrypts to your GitHub-published keys)
#   - kubectl
#
# Flags:
#   --ttl N           Token lifetime in hours (1-24, default 8).
#   --key  <path>     Private SSH key to decrypt with. Default ~/.ssh/id_ed25519.
#   --out  <path>     Where to write the kubeconfig. Default ~/.kube/config.
#                     If the file already exists it is backed up to <path>.bak.
#   --repo owner/name Override the repo to dispatch against. Default
#                     antinvestor/deployments.
#   -h, --help        Show this help.
#
# Usage:
#   ./scripts/get-kubeconfig.sh
#   ./scripts/get-kubeconfig.sh --ttl 24 --out ~/.kube/antinvestor.yaml
#   KUBECONFIG=~/.kube/antinvestor.yaml kubectl get nodes

set -euo pipefail

# ---- defaults ----
TTL=8
KEY="${HOME}/.ssh/id_ed25519"
OUT="${HOME}/.kube/config"
REPO="antinvestor/deployments"
WORKFLOW="dispatch-kubeconfig.yml"

usage() { sed -n '2,34p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ; exit 1 ; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ttl)    TTL="$2"; shift 2 ;;
    --key)    KEY="$2"; shift 2 ;;
    --out)    OUT="$2"; shift 2 ;;
    --repo)   REPO="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2 ; usage ;;
  esac
done

say()  { printf '\e[1;34m[%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$*" ; }
die()  { printf '\e[1;31m[%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$*" >&2 ; exit 1 ; }

for cmd in gh age kubectl jq ; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing: $cmd"
done

[[ -r "$KEY" ]] || die "SSH private key not readable at $KEY (override with --key)"

# 1. Dispatch the workflow.
say "Dispatching $WORKFLOW (ttl=${TTL}h) against $REPO"
gh workflow run "$WORKFLOW" --ref main -R "$REPO" -f ttl_hours="$TTL" >/dev/null

# 2. Resolve the new run id — poll briefly because GitHub may lag a second or two.
say "Waiting for the run to register..."
RUN_ID=""
for _ in $(seq 1 20) ; do
  RUN_ID=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --limit 1 --json databaseId,status \
    --jq '.[] | select(.status=="queued" or .status=="in_progress") | .databaseId' 2>/dev/null \
    | head -1 || true)
  [[ -n "$RUN_ID" ]] && break
  sleep 2
done
[[ -n "$RUN_ID" ]] || die "Could not locate the dispatched run."
say "Run id: $RUN_ID — $(gh run view "$RUN_ID" -R "$REPO" --json url --jq .url)"

# 3. Wait for it to finish.
say "Waiting for run to complete..."
gh run watch "$RUN_ID" -R "$REPO" --exit-status >/dev/null

# 4. Download + decrypt.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
gh run download "$RUN_ID" -R "$REPO" -n kubeconfig -D "$TMP"
[[ -s "$TMP/kubeconfig.age" ]] || die "Downloaded artifact is empty."

# 5. Decrypt.
mkdir -p "$(dirname "$OUT")"
if [[ -f "$OUT" ]]; then
  cp "$OUT" "${OUT}.bak"
  say "Existing $OUT backed up to ${OUT}.bak"
fi
age -d -i "$KEY" -o "$OUT" "$TMP/kubeconfig.age"
chmod 600 "$OUT"
say "Wrote kubeconfig to $OUT"

# 6. Smoke test.
say "Cluster:"
KUBECONFIG="$OUT" kubectl get nodes
echo ""
say "Ready. Use:  export KUBECONFIG=$OUT"
