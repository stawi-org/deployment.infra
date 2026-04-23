#!/usr/bin/env bash
# scripts/create-cluster-user.sh
#
# Directly creates a Kubernetes user in the running cluster by minting a
# client certificate via the CertificateSigningRequest API and binding them
# to a role. Emits a ready-to-use kubeconfig.
#
# Unlike scripts/get-kubeconfig.sh (which issues a short-lived ServiceAccount
# token for the caller via GitHub Actions), this script creates a LONG-LIVED
# cluster identity with its own keypair + client cert. Use for collaborators
# who need stable access without going through a workflow.
#
# Prereqs:
#   - kubectl, configured with a kubeconfig that has rights to:
#       * certificatesigningrequests (create, approve, get)
#       * clusterrolebindings / rolebindings (create)
#     (the kubeconfig produced by scripts/get-kubeconfig.sh works).
#   - openssl.
#
# Usage:
#   scripts/create-cluster-user.sh <username> [namespace ...]
#   scripts/create-cluster-user.sh <username> --all-namespaces
#
# Flags/args:
#   <username>            Kubernetes user name (goes into the cert CN).
#   <namespace> ...       One or more namespaces to bind `admin` in.
#   --all-namespaces      Bind cluster-admin instead of per-namespace admin.
#   --out <path>          Kubeconfig output path.
#                         Default: credentials/<username>/kubeconfig.
#   --ttl-days <N>        Certificate lifetime. Default 365. Requires
#                         kube-apiserver flag --cluster-signing-duration (or
#                         signer-specific equivalent) to exceed this value.
#
# Examples:
#   scripts/create-cluster-user.sh alice staging dev
#   scripts/create-cluster-user.sh ops --all-namespaces --ttl-days 90
#   scripts/create-cluster-user.sh bob payments --out /tmp/bob.kubeconfig
#
# The kubeconfig is also stored at credentials/<username>/ alongside the key
# and cert so the user's credentials live in one place. credentials/<user>/
# is gitignored.

set -euo pipefail

# ---- defaults ----
OUT=""
TTL_DAYS=365

# ---- parse ----
if [[ $# -lt 1 ]]; then
  sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
fi

USER_NAME=""
NAMESPACES=()
ALL_NAMESPACES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)             OUT="$2"; shift 2 ;;
    --ttl-days)        TTL_DAYS="$2"; shift 2 ;;
    --all-namespaces)  ALL_NAMESPACES=true; shift ;;
    -h|--help)
      sed -n '2,39p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    -*)
      echo "unknown flag: $1" >&2; exit 2 ;;
    *)
      if [[ -z "$USER_NAME" ]]; then
        USER_NAME="$1"
      else
        NAMESPACES+=("$1")
      fi
      shift ;;
  esac
done

[[ -n "$USER_NAME" ]] || { echo "missing <username>" >&2; exit 2; }

for cmd in kubectl openssl ; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "missing: $cmd" >&2; exit 2; }
done

CRED_DIR="credentials/${USER_NAME}"
CSR_NAME="${USER_NAME}-csr"
: "${OUT:=${CRED_DIR}/kubeconfig}"

mkdir -p "$CRED_DIR" "$(dirname "$OUT")"
umask 077

say()  { printf '\e[1;34m[%s]\e[0m %s\n' "$(date +%H:%M:%S)" "$*" ; }

if ! $ALL_NAMESPACES && (( ${#NAMESPACES[@]} == 0 )) ; then
  echo "⚠️ No namespaces specified and --all-namespaces not set." >&2
  echo "   The user will authenticate but have zero permissions." >&2
  echo "   Pass namespaces as positional args or use --all-namespaces." >&2
  exit 2
fi

# === 1. Private key + CSR ===
say "Generating keypair + CSR in $CRED_DIR/"
openssl genrsa -out "${CRED_DIR}/pem.key" 2048 2>/dev/null
openssl req -new -key "${CRED_DIR}/pem.key" \
  -subj "/CN=${USER_NAME}/O=${USER_NAME}-group" \
  -out "${CRED_DIR}/pem.csr" 2>/dev/null

# === 2. Submit CSR to the cluster ===
say "Submitting CertificateSigningRequest ${CSR_NAME} (expiry=${TTL_DAYS}d)"
# Delete any stale CSR with the same name from a prior run so the submission
# is idempotent. Ignore not-found.
kubectl delete csr "$CSR_NAME" --ignore-not-found >/dev/null
EXPIRY_SECONDS=$(( TTL_DAYS * 86400 ))
kubectl apply -f - >/dev/null <<YAML
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: ${CSR_NAME}
spec:
  groups:
  - system:authenticated
  request: $(base64 < "${CRED_DIR}/pem.csr" | tr -d '\n')
  signerName: kubernetes.io/kube-apiserver-client
  expirationSeconds: ${EXPIRY_SECONDS}
  usages:
  - client auth
YAML

# === 3. Approve and retrieve the signed certificate ===
say "Approving CSR"
kubectl certificate approve "$CSR_NAME" >/dev/null

# The signer is async — wait briefly for .status.certificate to be populated.
for _ in $(seq 1 30) ; do
  CERT_B64=$(kubectl get csr "$CSR_NAME" -o jsonpath='{.status.certificate}' 2>/dev/null || true)
  [[ -n "$CERT_B64" ]] && break
  sleep 1
done
[[ -n "$CERT_B64" ]] || { echo "CSR was not signed within 30s" >&2; exit 1; }
echo "$CERT_B64" | base64 -d > "${CRED_DIR}/pem.crt"

# === 4. Build kubeconfig ===
say "Building kubeconfig at $OUT"
CLUSTER_NAME=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}')
CLUSTER_SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
CA_CERT=$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

kubectl config set-cluster "${CLUSTER_NAME}" \
  --server="${CLUSTER_SERVER}" \
  --certificate-authority=<(echo "${CA_CERT}" | base64 -d) \
  --embed-certs=true \
  --kubeconfig="$OUT" >/dev/null
kubectl config set-credentials "${USER_NAME}" \
  --client-certificate="${CRED_DIR}/pem.crt" \
  --client-key="${CRED_DIR}/pem.key" \
  --embed-certs=true \
  --kubeconfig="$OUT" >/dev/null
kubectl config set-context "${USER_NAME}@${CLUSTER_NAME}" \
  --cluster="${CLUSTER_NAME}" \
  --user="${USER_NAME}" \
  --kubeconfig="$OUT" >/dev/null
kubectl config use-context "${USER_NAME}@${CLUSTER_NAME}" --kubeconfig="$OUT" >/dev/null

# === 5. RBAC ===
if $ALL_NAMESPACES ; then
  say "Granting cluster-admin to ${USER_NAME} (all namespaces)"
  kubectl create clusterrolebinding "${USER_NAME}-admin-binding" \
    --clusterrole=cluster-admin \
    --user="${USER_NAME}" 2>/dev/null || \
    kubectl patch clusterrolebinding "${USER_NAME}-admin-binding" --type merge \
      -p "{\"subjects\":[{\"apiGroup\":\"rbac.authorization.k8s.io\",\"kind\":\"User\",\"name\":\"${USER_NAME}\"}]}" >/dev/null
else
  for ns in "${NAMESPACES[@]}" ; do
    say "Granting admin in namespace: ${ns}"
    kubectl -n "$ns" create rolebinding "${USER_NAME}-admin-binding" \
      --clusterrole=admin \
      --user="${USER_NAME}" 2>/dev/null || \
      kubectl -n "$ns" patch rolebinding "${USER_NAME}-admin-binding" --type merge \
        -p "{\"subjects\":[{\"apiGroup\":\"rbac.authorization.k8s.io\",\"kind\":\"User\",\"name\":\"${USER_NAME}\"}]}" >/dev/null
    # Pin the last-listed namespace as the kubeconfig context default.
    kubectl config set-context "${USER_NAME}@${CLUSTER_NAME}" \
      --namespace="$ns" \
      --kubeconfig="$OUT" >/dev/null
  done
fi

chmod 600 "$OUT" "${CRED_DIR}/pem.key" "${CRED_DIR}/pem.crt"

say "✅ Done."
echo ""
echo "   Kubeconfig:  $OUT"
echo "   Key/cert:    ${CRED_DIR}/pem.key , ${CRED_DIR}/pem.crt"
echo ""
echo "   Share the kubeconfig with ${USER_NAME}. They use it with:"
echo "     KUBECONFIG=$OUT kubectl get nodes"
