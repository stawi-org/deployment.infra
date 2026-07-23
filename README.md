# deployment.infra

Talos Kubernetes cluster provisioning for the Stawi platform, via OpenTofu on Contabo VPS, Oracle Cloud Infrastructure, and GCP GCE workers.

![Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)

## Purpose

This repository owns everything required to bring up, tear down, or replace the cluster:

- Talos machine-config generation (layer 00)
- Contabo VPS fleet provisioning (layer 01)
- Oracle Cloud VM provisioning (layer 02)
- GCP GCE Spot worker provisioning (layer 02-gcp)
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
              +----------+----------+----------+----------+
              |          |          |          |          |
              v          v          v          v          v
        Contabo API  Oracle API  GCP API   On-prem inventory
              |          |          |          |
              v          v          v          v
         VPS control  OCI nodes  Spot GCE  Manual Talos
            plane     workers    workers     nodes
              |          |          |          |
              +----+-----+----+-----+----------+
                         v
                  Talos nodes + KubeSpan mesh (layer 03)
                  (high-throughput multi-site mesh; see docs/network-throughput.md)
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

Cluster inventory is driven by a folder in the same R2 bucket as OpenTofu
state, under `production/config/`. Keep one YAML file per account or site:

| Object | Purpose |
|---|---|
| `production/config/contabo/<account>.yaml` | One Contabo account and all of its nodes. |
| `production/config/oci/<account>.yaml` | One OCI account and all of its nodes. |
| `production/config/onprem/<account>.yaml` | One on-prem account and all declared nodes. |
| `production/inventory/gcp/<account>/nodes.yaml` | GCP project node inventory (R2). Auth/WIF lives in-repo under `tofu/shared/accounts/gcp/<account>/auth.yaml`; roster under `gcp:` in `tofu/shared/accounts.yaml`. |

The reusable workflow consumes every YAML file under `production/config/` and
aggregates them by provider. Provider-specific objects and secret ladders are
no longer consumed by the workflow. GCP follows the R2 inventory model used by
live node state: `production/inventory/gcp/<account>/nodes.yaml`.

The structure is:

- `contabo/<account>.yaml`: Contabo credentials plus grouped node inventory.
- `oci/<account>.yaml`: OCI auth, tenancy, network, and node inventory.
- `onprem/<location>.yaml`: Physical-site inventory and optional hints.
- `gcp/<account>/nodes.yaml` (R2): GCE workers only; default pack is two Spot `e2-standard-2` (8 GiB) VMs after onboard.

Contabo node names and OCI node names must remain RFC 1123-safe and unique
within the cluster. The inventory compiler uses the account and node keys to
render provider-specific Terraform variables.

Node `role` is explicit in every provider inventory. It currently determines
whether layer 03 renders a controlplane or worker Talos machine config, and it
drives the standardized node-role labels alongside the provider-specific
metadata.

Contabo, OCI, GCP, and on-prem all support `labels` and `annotations` at both the
account/location level and the node level. Node-level keys override the
account/location defaults for the same field. On-prem nodes also keep IPs
optional because they may change.
On-prem node `region` defaults to the location's `region`, but you can set it
per node when a site needs an explicit override.

OCI accounts are IPv6-enabled by default. Each VCN receives an Oracle-assigned
IPv6 prefix, each private worker subnet receives an IPv6 subnet, and worker
VNICs receive IPv6 addresses that flow into the Talos node contract.

The rendered Talos bundle is also archived back into R2 as an encrypted
`tar.gz.age` under `production/audit/talos-configs/<run-id>/<sha>/` for later
reference or audit.

Upload example:

```bash
aws s3 sync production/config/contabo/ \
  s3://cluster-tofu-state/production/config/contabo/ \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
aws s3 sync production/config/oci/ \
  s3://cluster-tofu-state/production/config/oci/ \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
aws s3 sync production/config/onprem/ \
  s3://cluster-tofu-state/production/config/onprem/ \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  --region us-east-1
```

Example file layout:

```text
production/config/
  contabo/
    stawi-contabo.yaml
  oci/
    stawi-a.yaml
  onprem/
    kampala-hq.yaml

production/inventory/
  gcp/
    stawi-prod/
      nodes.yaml
```

See [docs/config/gcp/stawi-prod.yaml](docs/config/gcp/stawi-prod.yaml) for an
example GCP account shape (docs only; live nodes are the R2 inventory path).

Example `production/config/oci/stawi-a.yaml`:

```yaml
oci:
  accounts:
    stawi-a:
      tenancy_ocid: ocid1.tenancy.oc1..example
      compartment_ocid: ocid1.compartment.oc1..example
      region: eu-frankfurt-1
      vcn_cidr: 10.200.0.0/16
      enable_ipv6: true
      labels:
        node.stawi.org/capacity-pool: ampere-a1
      annotations:
        node.stawi.org/account-owner: platform
      auth:
        domain_base_url: https://idcs-example.identity.oraclecloud.com
        oidc_client_identifier: "<clientId>:<clientSecret>"
      nodes:
        wk-1:
          role: worker
          # Continuous Always Free A1: ≤2 OCPU + ≤12 GB total per tenancy;
          # boot sum ≤196 (200 free − 4 GB buffer). Shape A1.Flex; ≤2 nodes.
          shape: VM.Standard.A1.Flex
          ocpus: 2
          memory_gb: 12
          boot_volume_size_gb: 196
          labels:
            node.stawi.org/workload-class: edge
          annotations:
            node.stawi.org/operator-note: primary-oci-worker
```

### GitHub Repository Variables

This optional variable remains available for decommissioning:

| Variable | Purpose |
|---|---|
| `OCI_RETAINED_PROFILES` | Comma-separated OCI profile names that remain provider-only for one apply during account decommissioning. |

## Bringup sequence

**Preferred:** one orchestrated path — see [docs/cluster-provision.md](docs/cluster-provision.md).

```bash
# Day-2: OpenTofu apply only (desired nodes / networks)
gh workflow run cluster-provision.yml -f mode=infra

# Full path: idempotent image import + tofu-apply + template + Flux
gh workflow run cluster-provision.yml -f mode=full -f deploy_flux=true
```

Desired state lives in **OpenTofu** (plus R2 inventory). Image *bytes* need Omni (`sync-talos-images`); imports and downloads are idempotent. Existing VMs are not recreated when the image catalog changes.

**GCP onboard:** [docs/gcp-onboard.md](docs/gcp-onboard.md). Bootstrap WIF once (`bootstrap-gcp-wif.sh` → PR). After merge, OpenTofu creates the default **two Spot workers** when inventory is empty — no separate seed script. CI uses GitHub OIDC → WIF (no long-lived SA JSON keys).

**Node labels:** match deployment.manifests (CNPG uses `role-database` + `provider`) — [docs/node-labels.md](docs/node-labels.md). **Secrets:** [SECURITY.md](SECURITY.md) if the repo is ever made public.

Layer-by-layer (still supported): each layer via `workflow_dispatch` of `tofu-plan` / `tofu-apply` → `tofu-layer.yml`.

1. **Layer 00 — Talos secrets.**
2. **Layer 01 — Contabo infra.**
3. **Layer 02 — Oracle infra** (Always Free caps enforced at plan time; see [docs/oci-always-free.md](docs/oci-always-free.md)).
4. **Layer 02-gcp — GCP infra** (Spot GCE workers; WIF auth; default two workers per empty account).
5. **Layer 02-onprem — On-prem inventory.**
6. **Layer 03 — Talos** (MachineLabels + per-node patches to R2).
7. **Layer 04 — DNS** (runs in parallel with talos after infra).
8. **Flux** via `deploy-flux` (also called from `cluster-provision`).

### Topology boundary

The current production-safe topology keeps the Talos control plane on Contabo
and treats OCI, GCP, and on-prem as workers joined through KubeSpan. GCP is
**workers only**, Spot by default. This avoids stretching etcd quorum across
unmanaged WAN paths. For provider/location control-plane survivability, prefer
multiple clusters reconciled from the same GitOps source rather than one
WAN-stretched etcd cluster. See [docs/topology.md](docs/topology.md) for the
detailed boundary.

### Flux GitHub App prerequisite

Layer 04 requires a Flux GitHub App that is **installed on `stawi-org/deployment.manifest`** so `source-controller` can clone the repo. A dedicated Flux App for `stawi-org` is planned but not yet created — in the interim, install the existing Flux App on `stawi-org` or defer layer 04 until the dedicated App is registered. The `validate-flux-gh-secrets` smoke test below will surface this as "installation not found" if the App isn't installed on the target org.

### Smoke tests

- `validate-flux-gh-secrets` workflow confirms the three `FLUX_GITHUB_APP_*` secrets are syntactically correct and the App is reachable. Run after populating those three secrets. A green result confirms credentials + installation; "installation not found" means the App needs to be installed on `stawi-org`.

## Teardown

- `tofu-reinstall` opens a cluster-reset PR with the requested reason.
- `reset-cluster` runs after that PR is approved and merged, or via manual
  `workflow_dispatch` for break-glass use.
- See [docs/reset-approval.md](docs/reset-approval.md) for the exact request
  -> approval -> execution flow.
- `wipe-flux-crds` / `wipe-flux-namespace` workflows clean up Flux state without touching Talos.
- Destroy order for a full tear-down: layer 04 -> layer 03 -> layer 02-onprem -> layer 02-gcp -> layer 02-oracle -> layer 01. Layer 00 (secrets) is left alone unless you're rotating.

## Related repositories

- **[stawi-org/deployment.manifest](https://github.com/stawi-org/deployment.manifest)** — Kubernetes manifests FluxCD reconciles onto the cluster.

## Contributing

- Run `make verify` before opening a PR.
- The CI validates `tofu fmt -check` and `tofu validate` for every layer on PR.
- Security reports: use GitHub private advisories.

## License

Apache License, Version 2.0 — see [LICENSE](LICENSE).
