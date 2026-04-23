# tofu/layers/04-flux/flux.tf
# Layer 04 installs the Flux Operator (https://fluxcd.control-plane.io/operator/)
# and declares a FluxInstance that tells the operator to stand up the Flux
# controllers and start syncing from this repo. The operator approach replaces
# the earlier flux_bootstrap_git flow because:
#
#   - FluxInstance is the canonical, declarative way to pin Flux distribution
#     + set up a GitRepository + Kustomization in one CR.
#   - No short-lived bootstrap token with 1-hour TTL (the pullSecret uses the
#     same GitHub App credentials that source-controller regenerates from).
#
# Ownership split with the repo:
#   - tofu owns: flux-system namespace, sops-age-keys (SOPS decryption),
#     ghapp-secret (GitHub App creds for source-controller), the FluxInstance
#     resource itself.
#   - Repo (reconciled by FluxInstance-created Kustomization) owns: everything
#     under manifests/common-setup, manifests/providers, etc.

resource "kubernetes_namespace" "flux_system" {
  metadata {
    name = "flux-system"
    labels = {
      "app.kubernetes.io/instance" = "flux-system"
      "app.kubernetes.io/part-of"  = "flux"
    }
  }
}

# SOPS age key used by kustomize-controller to decrypt SOPS-encrypted secrets
# in the repo. Name MUST match decryption.secretRef.name in
# manifests/flux-system/deployments.yaml.
resource "kubernetes_secret" "sops_age_keys" {
  metadata {
    name      = "sops-age-keys"
    namespace = kubernetes_namespace.flux_system.metadata[0].name
  }
  data = {
    "age.agekey" = data.terraform_remote_state.secrets.outputs.sops_age_key
  }
  type = "Opaque"
}

# GitHub App credentials consumed by source-controller for git authentication
# against this repo. Referenced by FluxInstance.spec.sync.pullSecret. The three
# keys (githubAppID / githubAppInstallationID / githubAppPrivateKey) are the
# exact names source-controller expects per
# https://fluxcd.io/flux/components/source/gitrepositories/#github-app.
resource "kubernetes_secret" "ghapp" {
  metadata {
    name      = "ghapp-secret"
    namespace = kubernetes_namespace.flux_system.metadata[0].name
  }
  data = {
    githubAppID             = var.github_app_id
    githubAppInstallationID = var.github_app_installation_id
    githubAppPrivateKey     = var.github_app_private_key
  }
  type = "Opaque"
}

# Talosconfig secret consumed by the etcd-backup CronJob's initContainer.
resource "kubernetes_secret" "talosconfig" {
  metadata {
    name      = "talosconfig"
    namespace = "kube-system"
  }
  data = {
    "config" = data.terraform_remote_state.talos.outputs.talosconfig
  }
  type = "Opaque"
}

# R2 credentials for the etcd-backup CronJob's upload container.
resource "kubernetes_secret" "r2_etcd_backup_credentials" {
  metadata {
    name      = "r2-etcd-backup-credentials"
    namespace = "kube-system"
  }
  data = {
    AWS_ACCESS_KEY_ID     = var.etcd_backup_r2_access_key_id
    AWS_SECRET_ACCESS_KEY = var.etcd_backup_r2_secret_access_key
    R2_ACCOUNT_ID         = var.r2_account_id
  }
  type = "Opaque"
}

# Flux Operator — installs the FluxInstance CRD + the controller that
# reconciles FluxInstance resources into actual Flux controller deployments.
resource "helm_release" "flux_operator" {
  depends_on = [kubernetes_namespace.flux_system]
  name       = "flux-operator"
  repository = "oci://ghcr.io/controlplaneio-fluxcd/charts"
  chart      = "flux-operator"
  namespace  = kubernetes_namespace.flux_system.metadata[0].name
  timeout    = 300
  # wait=false: helm returns as soon as manifests are applied. The CRDs
  # (FluxInstance, ResourceSet, ...) are registered synchronously during
  # chart install, so the later kubectl_manifest that applies FluxInstance
  # will find the CRD. The operator pod coming ready shortly afterwards is
  # what reconciles FluxInstance into a running Flux stack; tofu doesn't
  # need to block on that.
  wait   = false
  atomic = false

  # Tolerate control-plane taints so the operator can schedule on CPs when
  # there are no worker nodes (e.g. during initial bootstrap before the OCI
  # worker joins, or in single-CP dev setups).
  values = [yamlencode({
    tolerations = [
      { key = "node-role.kubernetes.io/control-plane", operator = "Exists", effect = "NoSchedule" },
    ]
  })]
}

# FluxInstance — the declarative spec the Flux Operator reconciles into a
# running Flux installation. Kept as an in-repo YAML so the git history tracks
# changes to what's deployed.
resource "kubectl_manifest" "flux_instance" {
  depends_on = [
    helm_release.flux_operator,
    kubernetes_secret.ghapp,
    kubernetes_secret.sops_age_keys,
  ]
  yaml_body = file("${path.module}/../../../manifests/flux-system/fluxcd-setup.yaml")
  # Don't block on FluxInstance reaching Ready — the controller is
  # eventually-consistent and tofu apply needs to return. Reconcile status
  # can be checked out-of-band via `kubectl get fluxinstance -A`.
  wait = false
}
