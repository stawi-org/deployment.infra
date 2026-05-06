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

# Generic install helper: download to a temp file, chmod, then
# `install -m 0755` into install_dir. Skips when target already
# carries the requested version (idempotent re-runs).
install_bin() {
  local name="$1" url="$2" version_check="$3" want_version="$4"
  local target="${install_dir}/${name}"

  if [[ -x "$target" ]] && bash -c "$version_check" 2>/dev/null \
      | grep -qF "$want_version"; then
    echo "[setup-kubectl] $name already at $want_version — skipping"
    return 0
  fi
  echo "[setup-kubectl] $name → $url"
  curl -fsSL -o "$tmp/${name}" "$url"
  chmod +x "$tmp/${name}"
  $use_sudo install -m 0755 "$tmp/${name}" "$target"
}

# 1. kubectl. Direct binary download from dl.k8s.io. The version
# check is tolerant of upstream output churn — both `kubectl
# version --client --output=yaml` and the legacy `--short` form work.
install_bin kubectl \
  "https://dl.k8s.io/release/${K8S_VERSION}/bin/${OS}/${ARCH}/kubectl" \
  "${install_dir}/kubectl version --client --output=yaml 2>/dev/null" \
  "${K8S_VERSION#v}"

# 2. kubelogin. Released as a zip with the bare `kubelogin` binary
# inside. We rename to `kubectl-oidc_login` because that's the
# filename kubectl uses to discover the OIDC plugin (kubectl exec-
# plugin lookup: `kubectl-<name with _ instead of - and . instead of
# space>` is found in PATH). Omni's kubeconfig exec.command is
# literally `kubectl-oidc_login`.
zip_url="https://github.com/int128/kubelogin/releases/download/${KUBELOGIN_VERSION}/kubelogin_${OS}_${ARCH}.zip"
target_kl="${install_dir}/kubectl-oidc_login"
if [[ -x "$target_kl" ]] \
    && "$target_kl" --version 2>/dev/null | grep -qF "${KUBELOGIN_VERSION#v}"; then
  echo "[setup-kubectl] kubectl-oidc_login already at $KUBELOGIN_VERSION — skipping"
else
  echo "[setup-kubectl] kubelogin → $zip_url"
  curl -fsSL -o "$tmp/kl.zip" "$zip_url"
  unzip -qq -o "$tmp/kl.zip" -d "$tmp/kl"
  $use_sudo install -m 0755 "$tmp/kl/kubelogin" "$target_kl"
fi

# 3. omnictl. Direct binary, same pattern as kubectl.
install_bin omnictl \
  "https://github.com/siderolabs/omni/releases/download/${OMNI_VERSION}/omnictl-${OS}-${ARCH}" \
  "${install_dir}/omnictl --version 2>/dev/null" \
  "${OMNI_VERSION#v}"

echo "[setup-kubectl] toolchain installed:"
"${install_dir}/kubectl" version --client --output=yaml | head -3
"${install_dir}/omnictl" --version | head -1
"${install_dir}/kubectl-oidc_login" --version | head -1

# 4. Configure omnictl context. Idempotent: `omnictl config add-
# context` updates the existing context if it already exists.
echo "[setup-kubectl] configuring omnictl context for $OMNI_ENDPOINT"
"${install_dir}/omnictl" config add-context "$OMNI_CLUSTER" \
  --url "$OMNI_ENDPOINT" >/dev/null
"${install_dir}/omnictl" config use-context "$OMNI_CLUSTER" >/dev/null

# 5. Issue + merge kubeconfig. The first run opens a browser for
# OIDC login; subsequent runs reuse the cached token in
# ~/.kube/cache/oidc-login/. `--merge=true` is the default — we
# pass it explicitly for clarity. The kubeconfig context name comes
# from Omni and is `<cluster>` by default.
echo "[setup-kubectl] fetching kubeconfig (browser may open for OIDC login)"
"${install_dir}/omnictl" kubeconfig --cluster "$OMNI_CLUSTER" --merge=true

# 6. Verify connectivity.
echo "[setup-kubectl] verifying connectivity"
"${install_dir}/kubectl" --context "$OMNI_CLUSTER" get nodes -o wide

echo ""
echo "[setup-kubectl] done. Day-to-day usage:"
echo "  kubectl --context $OMNI_CLUSTER get pods -A"
echo "  kubectl --context $OMNI_CLUSTER get nodes -o wide"
echo ""
echo "If the OIDC token expires (~1 day), kubectl will reopen the"
echo "browser for re-auth automatically. Force re-auth: rm -rf"
echo "  ~/.kube/cache/oidc-login/"
