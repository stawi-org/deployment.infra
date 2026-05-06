#!/usr/bin/env bash
# Idempotent installer for the local toolchain needed to run kubectl
# against the stawi cluster:
#
#   - kubectl                       (k8s CLI)
#   - kubectl-oidc_login            (kubelogin plugin; Omni's
#                                    kubeconfig has an exec: block
#                                    that calls this for OIDC auth)
#   - omnictl                       (fetches kubeconfig from Omni)
#
# After install the script:
#   1. Sets up the omnictl context for cp.stawi.org.
#   2. Issues an Omni-OIDC kubeconfig and merges it into ~/.kube/config.
#   3. Runs `kubectl get nodes` to verify connectivity.
#
# Re-running is safe — already-installed binaries at the requested
# version are reused, omnictl context updates are no-ops, and the
# kubeconfig merge is idempotent (Omni issues the same context name).
#
# Defaults match the running cluster as of 2026-05-06:
#   - kubectl 1.36.0  (matches tofu/shared/versions.auto.tfvars.json)
#   - omnictl 1.7.1   (matches Omni server)
#   - kubelogin 1.32.4
#
# Usage:
#   scripts/setup-kubectl.sh
#   K8S_VERSION=v1.36.0 scripts/setup-kubectl.sh   # override
#   INSTALL_DIR=$HOME/.local/bin scripts/setup-kubectl.sh
#
# Env knobs:
#   K8S_VERSION       kubectl version (default v1.36.0)
#   OMNI_VERSION      omnictl version (default v1.7.1)
#   KUBELOGIN_VERSION kubelogin version (default v1.32.4)
#   OMNI_ENDPOINT     Omni URL (default https://cp.stawi.org)
#   OMNI_CLUSTER      cluster name (default stawi)
#   INSTALL_DIR       binary install dir (default /usr/local/bin via sudo;
#                     falls back to $HOME/.local/bin if no sudo)
#
# Requires: curl, install, unzip, plus sudo OR write access to
# INSTALL_DIR. Linux + macOS supported (auto-detected by uname).

set -euo pipefail

K8S_VERSION="${K8S_VERSION:-v1.36.0}"
OMNI_VERSION="${OMNI_VERSION:-v1.7.1}"
KUBELOGIN_VERSION="${KUBELOGIN_VERSION:-v1.32.4}"
OMNI_ENDPOINT="${OMNI_ENDPOINT:-https://cp.stawi.org}"
OMNI_CLUSTER="${OMNI_CLUSTER:-stawi}"

# OS / arch detection. Talos / Omni / kubectl release artefacts are
# named consistently across these tools (linux-amd64, linux-arm64,
# darwin-amd64, darwin-arm64), so one lookup suffices.
case "$(uname -s)" in
  Linux)  OS="linux"  ;;
  Darwin) OS="darwin" ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  x86_64|amd64) ARCH="amd64" ;;
  aarch64|arm64) ARCH="arm64" ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# Install dir resolution. /usr/local/bin needs sudo; if no sudo
# available (or user opted out via INSTALL_DIR), fall back to
# $HOME/.local/bin and remind the user to add it to PATH.
if [[ -n "${INSTALL_DIR:-}" ]]; then
  install_dir="$INSTALL_DIR"
  use_sudo=""
elif [[ -w /usr/local/bin ]]; then
  install_dir="/usr/local/bin"
  use_sudo=""
elif command -v sudo >/dev/null && sudo -n true 2>/dev/null; then
  install_dir="/usr/local/bin"
  use_sudo="sudo"
else
  install_dir="$HOME/.local/bin"
  use_sudo=""
  mkdir -p "$install_dir"
  case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) echo "::warning:: $install_dir is not on PATH; add it to your shell rc" ;;
  esac
fi
echo "[setup-kubectl] installing into $install_dir${use_sudo:+ (with sudo)}"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Returns 0 if the binary at $1 reports a version string containing
# the literal $2. Captures both stdout AND stderr because some tools
# (notably kubelogin) historically printed --version to stderr; merging
# 2>&1 makes us robust across releases. The remaining args are the
# subcommand to invoke (e.g. "version --client").
binary_at_version() {
  local bin="$1" want="$2"
  shift 2
  [[ -x "$bin" ]] || return 1
  "$bin" "$@" 2>&1 | grep -qF "$want"
}

# Install one binary from a direct URL, idempotently. Skips the
# download entirely when the target already reports the requested
# version. Args:
#   $1 friendly name (also the on-disk filename)
#   $2 URL to fetch
#   $3 want-version string (e.g. "1.36.0", no leading 'v')
#   $4..N argv to pass to the binary for version detection
install_bin() {
  local name="$1" url="$2" want="$3"
  shift 3
  local target="${install_dir}/${name}"

  if binary_at_version "$target" "$want" "$@"; then
    echo "[setup-kubectl] $name already at $want — skipping download"
    return 0
  fi
  echo "[setup-kubectl] $name → $url"
  curl -fsSL -o "$tmp/${name}" "$url"
  chmod +x "$tmp/${name}"
  $use_sudo install -m 0755 "$tmp/${name}" "$target"
}

# 1. kubectl. `kubectl version --client` writes "Client Version:
# v1.36.0" to stdout — substring match on "1.36.0" is reliable
# across 1.28+ (which removed --short).
install_bin kubectl \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/${OS}/${ARCH}/kubectl" \
  "${K8S_VERSION#v}" \
  version --client

# 2. kubelogin. Released as a zip with the bare `kubelogin` binary
# inside, so we can't use install_bin directly — we have to extract
# first. We rename the binary to `kubectl-oidc_login` because that's
# the filename kubectl's exec-plugin lookup uses (kubectl-<name with
# `_` for `-` and `.` for space>); Omni's kubeconfig exec.command is
# literally `kubectl-oidc_login`.
target_kl="${install_dir}/kubectl-oidc_login"
if binary_at_version "$target_kl" "${KUBELOGIN_VERSION#v}" --version; then
  echo "[setup-kubectl] kubectl-oidc_login already at $KUBELOGIN_VERSION — skipping download"
else
  zip_url="https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_${OS}_${ARCH}.zip"
  echo "[setup-kubectl] kubelogin → $zip_url"
  curl -fsSL -o "$tmp/kl.zip" "$zip_url"
  unzip -qq -o "$tmp/kl.zip" -d "$tmp/kl"
  $use_sudo install -m 0755 "$tmp/kl/kubelogin" "$target_kl"
fi

# 3. omnictl. `omnictl --version` writes "Client: Tag: v1.7.1" — the
# substring "1.7.1" is unambiguous.
install_bin omnictl \
  "https://github.com/siderolabs/omni/releases/download/${OMNI_VERSION}/omnictl-${OS}-${ARCH}" \
  "${OMNI_VERSION#v}" \
  --version

echo "[setup-kubectl] toolchain installed:"
"${install_dir}/kubectl" version --client --output=yaml | head -3
"${install_dir}/omnictl" --version | head -1
"${install_dir}/kubectl-oidc_login" --version | head -1

# 4. Configure omnictl context. The CLI uses `omnictl config add
# <name>` to create a context (NOT `add-context`), and `omnictl
# config url <url>` to (re)set the URL on the current context. We
# add the context first (idempotent on second run — `add` is a
# no-op if the context already exists with the same URL); then
# switch to it; then re-set the URL so a relocated Omni endpoint
# updates without complaint.
echo "[setup-kubectl] configuring omnictl context for $OMNI_ENDPOINT"
"${install_dir}/omnictl" config add "$OMNI_CLUSTER" \
  --url "$OMNI_ENDPOINT" >/dev/null 2>&1 || true
"${install_dir}/omnictl" config context "$OMNI_CLUSTER" >/dev/null
"${install_dir}/omnictl" config url "$OMNI_ENDPOINT" >/dev/null

# 5. Issue + merge OIDC kubeconfig. This script is operator-only —
# service-account-backed kubeconfigs (used in CI / workflows) are
# deliberately NOT supported here. SA keys are bound to identities
# with broad cluster privileges and shouldn't proliferate to
# workstations; per-operator OIDC keeps the audit trail tied to a
# real user.
#
# Pre-flight: probe `omnictl get user`. If it errors, the omniconfig
# at ~/.talos/omni/config doesn't yet have a working identity (no
# entry, expired key, or never went through the dashboard's first-
# run identity registration). Print clear setup steps and exit so
# the operator can complete identity registration before re-running.
if ! "${install_dir}/omnictl" get user >/dev/null 2>&1; then
  cat <<EOM
[setup-kubectl] omnictl is not yet authenticated against $OMNI_ENDPOINT.

First-time setup (do this once, then re-run this script):

  1. Open $OMNI_ENDPOINT in a browser and log in.
  2. Top-right user menu → "Download omniconfig". Save the file.
  3. Replace ~/.talos/omni/config with the downloaded file:
       mkdir -p ~/.talos/omni
       mv ~/Downloads/omniconfig ~/.talos/omni/config
  4. Re-run: scripts/setup-kubectl.sh

The downloaded omniconfig embeds a SideroV1 PGP key tied to YOUR
Omni identity — every kubectl call audits back to your account.
EOM
  exit 1
fi
echo "[setup-kubectl] omniconfig identity OK — issuing OIDC kubeconfig"
"${install_dir}/omnictl" kubeconfig \
  --cluster "$OMNI_CLUSTER" --merge=true --force

# 6. Verify connectivity. The context name from `omnictl kubeconfig`
# is `<cluster>` for OIDC-issued configs.
echo "[setup-kubectl] verifying connectivity (context=$OMNI_CLUSTER)"
"${install_dir}/kubectl" --context "$OMNI_CLUSTER" get nodes -o wide

echo ""
echo "[setup-kubectl] done. Day-to-day usage:"
echo "  kubectl --context $OMNI_CLUSTER get pods -A"
echo "  kubectl --context $OMNI_CLUSTER get nodes -o wide"
echo ""
echo "If the OIDC token expires (~1 day), kubectl will reopen the"
echo "browser for re-auth automatically. Force re-auth: rm -rf"
echo "  ~/.kube/cache/oidc-login/"
