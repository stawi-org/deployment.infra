# deployment.infra

Talos Kubernetes cluster provisioning for the Stawi platform, via OpenTofu on Contabo VPS and Oracle Cloud Infrastructure.

![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

## Purpose

This repository owns everything required to bring up, tear down, or replace the cluster:

- Talos machine-config generation (layer 00)
- Contabo VPS fleet provisioning (layer 01)
- Oracle Cloud VM provisioning (layer 02)
- On-premises location/node inventory (layer 02-onprem)
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
                Contabo API           Oracle Cloud API         On-prem inventory
                    |                     |                          |
                    v                     v                          v
              VPS control plane      OCI workers              Manual Talos workers
                    |                     |                          |
                    +----+----+----------+--------------------------+
                         v
                  Talos nodes + KubeSpan (layer 03)
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

## Cluster inventory in R2

Cluster inventory is driven by one canonical YAML file in the same R2 bucket
as OpenTofu state, under a separate `production/config/` folder:

| Object | Purpose |
|---|---|
| `production/config/cluster-inventory.yaml` | Canonical inventory for Contabo, OCI, and on-prem. |

The old provider-specific objects and secret ladders still work as bootstrap
fallbacks, but the scalable path is editing the canonical inventory file.

The structure is:

- `contabo.accounts.<account>`: Contabo credentials plus grouped node inventory.
- `oci.accounts.<account>`: OCI auth, tenancy, network, and worker inventory.
- `onprem.locations.<location>`: Physical-site inventory and optional hints.

Contabo node names and OCI worker names must remain RFC 1123-safe and unique
within the cluster. The inventory compiler uses the account and node keys to
render provider-specific Terraform variables.

Contabo account and node metadata can be attached with `labels` and
`annotations`. OCI account-level metadata applies to every worker in that
account, with worker-level keys overriding the account defaults.

OCI accounts are IPv6-enabled by default. Each VCN receives an Oracle-assigned
IPv6 prefix, each private worker subnet receives an IPv6 subnet, and worker
VNICs receive IPv6 addresses that flow into the Talos node contract.

Upload example:

```bash
aws s3 cp cluster-inventory.yaml \
  s3://cluster-tofu-state/production/config/cluster-inventory.yaml \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
```

Example `cluster-inventory.yaml`:

```yaml
contabo:
  accounts:
    stawi-contabo:
      auth:
        oauth2_client_id: "<clientId>"
        oauth2_client_secret: "<clientSecret>"
        oauth2_user: "<api-user>"
        oauth2_pass: "<api-password>"
      labels:
        node.antinvestor.io/capacity-pool: control-plane
      nodes:
        kubernetes-controlplane-api-1:
          role: controlplane
          product_id: V94
          region: EU
        kubernetes-controlplane-api-2:
          role: controlplane
          product_id: V94
          region: EU
        kubernetes-controlplane-api-3:
          role: controlplane
          product_id: V94
          region: EU
oci:
  accounts:
    stawi-a:
      tenancy_ocid: ocid1.tenancy.oc1..example
      compartment_ocid: ocid1.compartment.oc1..example
      region: eu-frankfurt-1
      vcn_cidr: 10.200.0.0/16
      enable_ipv6: true
      labels:
        node.antinvestor.io/capacity-pool: ampere-a1
      annotations:
        node.antinvestor.io/account-owner: platform
      auth:
        domain_base_url: https://idcs-example.identity.oraclecloud.com
        oidc_client_identifier: "<clientId>:<clientSecret>"
      workers:
        wk-1:
          shape: VM.Standard.A1.Flex
          ocpus: 4
          memory_gb: 24
onprem:
  locations:
    kampala-hq:
      region: UG
      site_ipv4_cidrs:
        - 192.0.2.0/24
      site_ipv6_cidrs:
        - 2001:db8:10::/64
      nodes:
        rack-1:
          labels:
            node.antinvestor.io/hardware-class: mini-pc
        rack-2:
          annotations:
            node.antinvestor.io/operator-note: dhcp-address-changes
```

### GitHub Repository Variables

These optional variables remain available for bootstrap and decommissioning:

| Variable | Purpose |
|---|---|
| `OCI_RETAINED_PROFILES` | Comma-separated OCI profile names that remain provider-only for one apply during account decommissioning. |
| `ONPREM_LOCATIONS_YAML` | Inline YAML fallback when the R2 on-prem object is not present. |

## Bringup sequence

Each layer is run via `workflow_dispatch` of the per-mode workflow, which dispatches to `tofu-layer.yml`. Plans are reviewed before apply.

1. **Layer 00 — Talos secrets.** Run `tofu-plan` with `layer=00-talos-secrets`, review, then `tofu-apply` with the same layer.
2. **Layer 01 — Contabo infra.** Same pattern. Provisions VPSes.
3. **Layer 02 — Oracle infra.** Same pattern. Provisions IPv4/IPv6 OCI workers (skip if no OCI slots populated).
4. **Layer 02-onprem — On-prem inventory.** Same pattern. Produces node contracts and Talos worker configs for declared physical locations.
5. **Layer 03 — Talos apply + bootstrap.** Same pattern. Applies machine configs to CI-reachable nodes, bootstraps etcd, and renders manual on-prem worker configs. Kubeconfig becomes available via `dispatch-kubeconfig` workflow.
6. **Layer 04 — Flux.** Same pattern. Installs Flux Operator, applies `FluxInstance` pointing at `stawi-org/deployment.manifest`. Verify FluxInstance reaches Ready with `kubectl get fluxinstance -A`.

### Topology boundary

The current production-safe topology keeps the Talos control plane on Contabo
and treats OCI plus on-prem as workers joined through KubeSpan. This avoids
stretching etcd quorum across unmanaged WAN paths. For provider/location
control-plane survivability, prefer multiple clusters reconciled from the same
GitOps source rather than one WAN-stretched etcd cluster. See
[docs/topology.md](docs/topology.md) for the detailed boundary.

### Flux GitHub App prerequisite

Layer 04 requires a Flux GitHub App that is **installed on `stawi-org/deployment.manifest`** so `source-controller` can clone the repo. A dedicated Flux App for `stawi-org` is planned but not yet created — in the interim, install the existing Flux App on `stawi-org` or defer layer 04 until the dedicated App is registered. The `validate-flux-gh-secrets` smoke test below will surface this as "installation not found" if the App isn't installed on the target org.

### Smoke tests

- `validate-flux-gh-secrets` workflow confirms the three `FLUX_GITHUB_APP_*` secrets are syntactically correct and the App is reachable. Run after populating those three secrets. A green result confirms credentials + installation; "installation not found" means the App needs to be installed on `stawi-org`.

## Teardown

- `reset-cluster` workflow performs a Talos-level cluster reset.
- `wipe-flux-crds` / `wipe-flux-namespace` workflows clean up Flux state without touching Talos.
- Destroy order for a full tear-down: layer 04 -> layer 03 -> layer 02-onprem -> layer 02-oracle -> layer 01. Layer 00 (secrets) is left alone unless you're rotating.

## Related repositories

- **[stawi-org/deployment.manifest](https://github.com/stawi-org/deployment.manifest)** — Kubernetes manifests FluxCD reconciles onto the cluster.

## Contributing

- Run `pre-commit run -a` before opening a PR.
- The CI validates `tofu fmt -check` and `tofu validate` for every layer on PR.
- Security reports: use GitHub private advisories.

## License

Apache License, Version 2.0 — see [LICENSE](LICENSE).
