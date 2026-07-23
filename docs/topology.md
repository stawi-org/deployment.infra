# Cluster Topology

This repository now has four node ownership modes:

1. **Contabo control plane**: layer `01-contabo-infra` provisions the Talos control-plane VPS fleet and publishes IPv4/IPv6 Cloudflare records.
2. **OCI nodes**: layer `02-oracle-infra` provisions nodes across OCI accounts. OCI networking is dual-stack by default. Account and node sizing comes from the canonical R2 inventory file.
3. **On-prem nodes**: layer `02-onprem-infra` declares physical site inventory and emits node contracts. Inventory uses `nodes` under `accounts`, plus labels, annotations, role, and region. Layer `03-talos` renders matching Talos node configs, but config application is manual because physical networks are not reachable from GitHub Actions by default. Account and node inventory also comes from the canonical R2 inventory file.
4. **GCP workers**: layer `02-gcp-infra` provisions paid GCE VMs across GCP projects. Auth is multi-project Workload Identity Federation (no long-lived SA JSON keys). Empty accounts seed a default pack of **two Spot `e2-standard-2` (8 GiB) workers** (OpenTofu defaults) in **`europe-west9` (Paris)** by default — closest French GCE region to Marseille. Spot uses **STOP** on preemption (not DELETE) so Talos/Omni identity survives; post-apply Omni twin cleanup is automatic. v1 is **workers only** (no control plane / etcd on GCE). **Stateful databases stay on OCI** (nodes labeled `node.stawi.org/db-eligible=false`). See [docs/gcp-lifecycle.md](gcp-lifecycle.md).

The canonical inventory lives under `production/config/` as multiple YAML files (legacy layout for Contabo/OCI/on-prem examples) and under R2 `production/inventory/` for per-account node state:

- `contabo/<account>.yaml`
- `oci/<account>.yaml`
- `onprem/<account>.yaml`
- `gcp/<account>/nodes.yaml` (R2: `production/inventory/gcp/<account>/nodes.yaml`)

Layer 03 aggregates those files by provider and account key.

Node-level `labels` and `annotations` are supported in every inventory file.
Provider/account defaults are merged first, then the node-level metadata is
applied so node-specific values win.

## Omni control plane

Omni (management plane for Talos) runs on **Contabo** VPS
`contabo-bwire-node-3` / `202727781` (Ubuntu + docker-compose), not as
a Talos node. DNS: `cp.stawi.org` (UI, orange-cloud) and
`cpd.stawi.org` (SideroLink / machine-api, gray-cloud). Layer:
`tofu/layers/00-omni-server` with `omni_host_provider = "contabo"`.

OCI Omni substrate exists but is **blocked** by eu-frankfurt-1 public
inbound blackholes (verified 2026-05-24 and 2026-07-18).

## Kubernetes control-plane boundary

The Kubernetes control plane is intentionally multi-account OCI for
Always Free packing, with Contabo providing stable worker capacity and
GCP adding Spot general-purpose workers. etcd quorum remains sensitive
to latency, packet loss, asymmetric routing, and correlated WAN failures.

Do not add unmanaged on-prem, OCI, or GCP control-plane nodes to this cluster without first introducing:

- measured site-to-site latency and packet loss SLOs,
- health-checked API endpoints,
- tested etcd quorum loss and recovery procedures,
- a rolling Talos upgrade path,
- provider/network failure drills.

For provider-level survivability, the preferred next architecture is multiple Talos clusters, each with a local control plane, reconciled from the same Flux source. That avoids stretching etcd across Contabo, OCI, GCP, and on-prem networks while still giving workload placement across all locations.

## IPv6 Model

- Kubernetes pod and service CIDRs are IPv6-first.
- Contabo control-plane nodes receive static IPv6 configuration.
- OCI worker VCNs, subnets, routes, security lists, and VNICs are IPv6-enabled by default.
- GCP workers are IPv4-first in v1 (VPC dual-stack / IPv6 is a follow-up).
- On-prem inventory records site IPv4/IPv6 CIDRs when known, but individual node IPs are optional last-known hints. The physical network remains responsible for router advertisements, DHCPv6, DNS, firewall policy, and address churn.

## Multi-site mesh (throughput first)

All providers join one cluster via **KubeSpan** (WireGuard) + Flannel. Design
goal: **high sustained throughput and robust any→any connectivity** no matter
where pods land (Contabo, OCI Frankfurt, GCP Paris, on-prem).

- Mesh is full-mesh; BBR + large TCP windows + MTU 1380 favor WAN goodput.
- Stateful DBs stay on **OCI** for capacity/Spot risk (`db-eligible=false` on GCP),
  not because the mesh cannot carry remote traffic.
- Locality labels exist for **optional** affinity only.

Primary guide: [docs/network-throughput.md](network-throughput.md).
Optional co-location: [docs/network-latency.md](network-latency.md).

## Sensitive Artifacts

Talos machine configs and `talosconfig` are sensitive. The `publish-talos-configs` workflow encrypts the bundle with age to the dispatching user's GitHub SSH public keys before uploading the artifact.
