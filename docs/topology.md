# Cluster Topology

This repository now has three node ownership modes:

1. **Contabo control plane**: layer `01-contabo-infra` provisions the Talos control-plane VPS fleet and publishes IPv4/IPv6 Cloudflare records.
2. **OCI nodes**: layer `02-oracle-infra` provisions nodes across OCI accounts. OCI networking is dual-stack by default. Account and node sizing comes from the canonical R2 inventory file.
3. **On-prem nodes**: layer `02-onprem-infra` declares physical site inventory and emits node contracts. Inventory uses `nodes` per location, plus labels, annotations, role, and region. Layer `03-talos` renders matching Talos node configs, but config application is manual because physical networks are not reachable from GitHub Actions by default. Location and node inventory also comes from the canonical R2 inventory file.

The canonical inventory lives under `production/config/` as multiple YAML files:

- `contabo/<account>.yaml`
- `oci/<account>.yaml`
- `onprem/<location>.yaml`

Layer 03 aggregates those files by provider and account key.

Node-level `labels` and `annotations` are supported in every inventory file.
Provider/account defaults are merged first, then the node-level metadata is
applied so node-specific values win.

## Control-Plane Boundary

The control plane remains intentionally provider-local to Contabo. This is the conservative option for a single Talos cluster because etcd quorum is sensitive to latency, packet loss, asymmetric routing, and correlated WAN failures.

Do not add unmanaged on-prem or OCI control-plane nodes to this cluster without first introducing:

- measured site-to-site latency and packet loss SLOs,
- health-checked API endpoints,
- tested etcd quorum loss and recovery procedures,
- a rolling Talos upgrade path,
- provider/network failure drills.

For provider-level survivability, the preferred next architecture is multiple Talos clusters, each with a local control plane, reconciled from the same Flux source. That avoids stretching etcd across Contabo, OCI, and on-prem networks while still giving workload placement across all locations.

## IPv6 Model

- Kubernetes pod and service CIDRs are IPv6-first.
- Contabo control-plane nodes receive static IPv6 configuration.
- OCI worker VCNs, subnets, routes, security lists, and VNICs are IPv6-enabled by default.
- On-prem inventory records site IPv4/IPv6 CIDRs when known, but individual node IPs are optional last-known hints. The physical network remains responsible for router advertisements, DHCPv6, DNS, firewall policy, and address churn.

## Sensitive Artifacts

Talos machine configs and `talosconfig` are sensitive. The `publish-talos-configs` workflow encrypts the bundle with age to the dispatching user's GitHub SSH public keys before uploading the artifact.
