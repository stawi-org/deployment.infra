# deployment.infra

Talos Kubernetes cluster provisioning for the Stawi platform, via OpenTofu on Contabo VPS and Oracle Cloud Infrastructure.

![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

## Purpose

This repository owns everything required to bring up, tear down, or replace the cluster:

- Talos machine-config generation (layer 00)
- Contabo VPS fleet provisioning (layer 01)
- Oracle Cloud VM provisioning (layer 02)
- Talos node configuration apply + bootstrap (layer 03)
- Flux Operator install + FluxInstance declaration that points the cluster at [stawi-org/deployment.manifest](https://github.com/stawi-org/deployment.manifest) (layer 04)

Once layer 04 has reconciled, the cluster is self-managing via FluxCD — application manifests land from the `deployment.manifest` repo, not this one.

## Architecture at a glance

```
[Operator] --workflow_dispatch--> tofu-plan / tofu-apply
                                    |
                                    v
                           GitHub Actions runner
                                    |
                         +----------+----------+
                         |                     |
                         v                     v
                Contabo API           Oracle Cloud API
                    |                     |
                    v                     v
                 VPS fleet           OCI workers (A1.Flex)
                    |                     |
                    +----+----+-----------+
                         v
                  Talos nodes (layer 03)
                         |
                         v
                  FluxCD (layer 04)
                         |
                         v
       syncs from stawi-org/deployment.manifest
```

## Prerequisites

Local tooling is only needed for pre-commit linting and offline validation:

- [OpenTofu](https://opentofu.org/) >= 1.8 (`tofu`)
- [pre-commit](https://pre-commit.com/) (`pip install pre-commit`)
- [tflint](https://github.com/terraform-linters/tflint), [tfsec](https://aquasecurity.github.io/tfsec/) (installed automatically by pre-commit on first run)
- [yq (mikefarah)](https://github.com/mikefarah/yq) for local YAML inspection

Cloud-side operations all run in GitHub Actions using the secrets below — no local cloud credentials are required unless you are operating out-of-band.

## GitHub Secrets required

All authentication material is sourced from **GitHub Actions secrets** (Settings -> Secrets and variables -> Actions). Nothing in this repository contains credentials; every reference is a `secrets.X` lookup at workflow runtime.

### Cloudflare R2 (tofu state backend)

| Secret | Purpose |
|---|---|
| `R2_ACCOUNT_ID` | R2 account identifier |
| `R2_ACCESS_KEY_ID` | R2 access key for state |
| `R2_SECRET_ACCESS_KEY` | R2 secret key for state |

### Contabo (VPS fleet — layer 01)

| Secret | Purpose |
|---|---|
| `CONTABO_CLIENT_ID` | OAuth2 client id for Contabo API |
| `CONTABO_CLIENT_SECRET` | OAuth2 client secret |
| `CONTABO_API_USER` | Contabo portal username |
| `CONTABO_API_PASSWORD` | Contabo portal password |

### Cloudflare (DNS + R2 bucket management)

| Secret | Purpose |
|---|---|
| `CLOUDFLARE_API_TOKEN` | DNS + R2 bucket management token |

### Flux bootstrap (layer 04)

| Secret | Purpose |
|---|---|
| `FLUX_GITHUB_APP_ID` | GitHub App ID for source-controller auth |
| `FLUX_GITHUB_APP_INSTALLATION_ID` | GitHub App installation ID |
| `FLUX_GITHUB_APP_PRIVATE_KEY` | GitHub App private key (PEM) |

### Cluster-side SOPS

| Secret | Purpose |
|---|---|
| `SOPS_AGE_KEY` | age private key matching the recipient in `deployment.manifest/.sops.yaml`, used by kustomize-controller to decrypt SOPS-encrypted manifests |

### Etcd backup

| Secret | Purpose |
|---|---|
| `ETCD_BACKUP_R2_ACCESS_KEY_ID` | R2 access key for etcd snapshots |
| `ETCD_BACKUP_R2_SECRET_ACCESS_KEY` | R2 secret key for etcd snapshots |

### Oracle Cloud (up to 4 accounts, slot ladder 0-3)

Per populated slot N (0, 1, 2, 3):

| Secret | Purpose |
|---|---|
| `OCI_PROFILE_N` | Profile name (must match the tofu `oci_accounts` key) |
| `OIDC_CLIENT_IDENTIFIER_N` | `<clientId>:<clientSecret>` for workload-identity federation |
| `OCI_DOMAIN_BASE_URL_N` | Identity-domain base URL (`https://idcs-...`) |
| `OCI_TENANCY_N` | Tenancy OCID |
| `OCI_REGION_N` | OCI region identifier |
| `OCI_VCN_CIDR_N` (optional) | VCN CIDR; defaults to `10.200.0.0/16` |
| `OCI_WORKERS_JSON_N` (optional) | Workers map JSON; defaults to single A1.Flex |

Empty slots are skipped automatically by the workflow.

## Bringup sequence

Each layer is run via `workflow_dispatch` of the per-mode workflow, which dispatches to `tofu-layer.yml`. Plans are reviewed before apply.

1. **Layer 00 — Talos secrets.** Run `tofu-plan` with `layer=00-talos-secrets`, review, then `tofu-apply` with the same layer.
2. **Layer 01 — Contabo infra.** Same pattern. Provisions VPSes.
3. **Layer 02 — Oracle infra.** Same pattern. Provisions OCI workers (skip if no OCI slots populated).
4. **Layer 03 — Talos apply + bootstrap.** Same pattern. Applies machine configs, bootstraps etcd. Kubeconfig becomes available via `dispatch-kubeconfig` workflow.
5. **Layer 04 — Flux.** Same pattern. Installs Flux Operator, applies `FluxInstance` pointing at `stawi-org/deployment.manifest`. Verify FluxInstance reaches Ready with `kubectl get fluxinstance -A`.

### Flux GitHub App prerequisite

Layer 04 requires a Flux GitHub App that is **installed on `stawi-org/deployment.manifest`** so `source-controller` can clone the repo. A dedicated Flux App for `stawi-org` is planned but not yet created — in the interim, install the existing Flux App on `stawi-org` or defer layer 04 until the dedicated App is registered. The `validate-flux-gh-secrets` smoke test below will surface this as "installation not found" if the App isn't installed on the target org.

### Smoke tests

- `validate-flux-gh-secrets` workflow confirms the three `FLUX_GITHUB_APP_*` secrets are syntactically correct and the App is reachable. Run after populating those three secrets. A green result confirms credentials + installation; "installation not found" means the App needs to be installed on `stawi-org`.

## Teardown

- `reset-cluster` workflow performs a Talos-level cluster reset.
- `wipe-flux-crds` / `wipe-flux-namespace` workflows clean up Flux state without touching Talos.
- Destroy order for a full tear-down: layer 04 -> layer 03 -> layer 02 -> layer 01. Layer 00 (secrets) is left alone unless you're rotating.

## Related repositories

- **[stawi-org/deployment.manifest](https://github.com/stawi-org/deployment.manifest)** — Kubernetes manifests FluxCD reconciles onto the cluster.

## Contributing

- Run `pre-commit run -a` before opening a PR.
- The CI validates `tofu fmt -check` and `tofu validate` for every layer on PR.
- Security reports: use GitHub private advisories.

## License

Apache License, Version 2.0 — see [LICENSE](LICENSE).
