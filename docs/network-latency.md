# Multi-site latency: seamless mesh, sub‑10 ms hot path

The cluster spans Contabo (EU), OCI (`eu-frankfurt-1`), GCP (`europe-west9`
Paris), and optional on‑prem. **Seamless connectivity** is KubeSpan + Flannel.
**Sub‑10 ms for almost all user-facing requests** is a **locality** property,
not a promise that every pod↔pod hop on the WAN is &lt;10 ms.

## Physics (honest budget)

| Path | Typical RTT (order of magnitude) |
|---|---|
| Same node / same zone (pod→pod local) | **&lt;1 ms** |
| Same provider region (e.g. two OCI ADs) | **1–3 ms** |
| Contabo EU ↔ OCI Frankfurt | **~5–15 ms** |
| GCP Paris ↔ OCI Frankfurt | **~8–20 ms** |
| WireGuard (KubeSpan) + Flannel overhead | **+0.2–1 ms** per hop |

One-way fiber ≈ 5 ms per 1000 km; Paris–Frankfurt is already several ms
before application work. **You cannot make every cross-cloud hop sub‑10 ms.**
You *can* make **almost all request paths** avoid that hop.

## Strategy: seamless mesh + locality for the hot path

```
┌─────────────────────────────────────────────────────────────┐
│  Any node can reach any node (KubeSpan WireGuard mesh)      │
│  Flannel pod networking with public-ip-overwrite on OCI/GCP │
└─────────────────────────────────────────────────────────────┘
           ▲
           │  cold / admin / background OK to cross sites
           │
┌──────────┴──────────┐     ┌──────────────────────────────┐
│ Hot path (sub-10ms) │     │ Elastic / batch (can be WAN) │
│ API + DB same site  │     │ GCP Spot general workers     │
│ OCI latency-domain  │     │ gcp-europe-west9             │
└─────────────────────┘     └──────────────────────────────┘
```

### Infrastructure (this repo)

| Mechanism | Purpose |
|---|---|
| **KubeSpan** enabled, `advertiseKubernetesNetworks: false` | Encrypted mesh; no default-route blackhole |
| **MTU 1380** | Avoid multi-cloud fragmentation |
| **`allowDownPeerBypass: true`** | Prefer direct peer endpoints |
| **Flannel public-ip-overwrite** (OCI/GCP) | Correct VXLAN under NAT |
| **UDP 51820 + 4789** open on workers | Mesh + overlay |
| **Topology labels** on every node | Affinity / topology-aware routing |
| **`node.stawi.org/latency-domain`** | Co-locate chatty pods (`oci-eu-frankfurt-1`, `gcp-europe-west9`, `contabo-eu`) |
| **`node.stawi.org/db-eligible=false`** on GCP | DBs stay on OCI |

### Workload placement (deployment.manifest — required for sub‑10 ms)

Without this, Kubernetes will happily place API on Paris Spot and DB on
Frankfurt Always Free → **every request pays WAN RTT**.

1. **Databases (CNPG, Redis that is latency-critical)**
   - `nodeSelector` / affinity: OCI (or Contabo), **not** GCP
   - Prefer `node.stawi.org/latency-domain: oci-eu-frankfurt-1`
   - Anti-affinity only within that domain for HA, not across providers for primary path

2. **API / request handlers that hit DB**
   - **Required** affinity to same `latency-domain` as their DB
   - Soft prefer non-Spot for single-replica if needed

3. **Stateless / cacheable / batch**
   - May use GCP Spot (`capacity-class=spot`)
   - Accept occasional WAN or use regional caches

4. **Services**
   - Enable topology-aware hints where available (`trafficDistribution: PreferClose` / topology aware routing) so kube-proxy prefers same-zone endpoints
   - Keep replica counts ≥1 **per latency domain** for critical services

5. **Ingress / edge**
   - Terminate close to users; route to in-region backends
   - Avoid hairpin: edge in FR → API in Frankfurt → DB in Frankfurt is fine if API+DB co-located

## Target SLOs

| Class | Latency target | How |
|---|---|---|
| **Hot path** (API + local DB, same latency-domain) | **p50 &lt; 5 ms, p99 &lt; 10 ms** app-level where query is simple | Locality + no WAN |
| **Mesh control** (any node reachability) | Best-effort, often 10–30 ms cross-site | KubeSpan always on |
| **Cross-domain optional path** | No sub‑10 ms guarantee | Design out of critical path |

“Almost all requests” = **almost all *user-facing request handling* stays inside one latency-domain**. Not “every Service ClusterIP hop is &lt;10 ms worldwide.”

## Verification

After nodes are Ready:

```bash
# Labels present
kubectl get nodes -L topology.kubernetes.io/region,node.stawi.org/latency-domain,node.stawi.org/provider

# Same-domain RTT (run from a pod on OCI)
# Install netperf/iperf or: curl -w '%{time_connect}\n' -o /dev/null -s http://<same-domain-svc>

# Cross-domain RTT (expect >10ms often)
# Same against a GCP-colocated service
```

Measure **application** latency (handler + DB), not only TCP connect.

## What not to do

| Anti-pattern | Result |
|---|---|
| Primary DB on OCI, default schedule API anywhere | Random WAN on every request |
| etcd / CP across Contabo+OCI+GCP without SLOs | Quorum risk (see topology.md) |
| Raise KubeSpan MTU to 1500 on multi-cloud | Fragmentation / silent drops |
| Expect Spot Paris ↔ Frankfurt DB &lt;10 ms always | Physics + Spot jitter |

## Summary

- **Seamless:** KubeSpan mesh already joins every provider; keep it, with MTU and Flannel overwrite.
- **Fast:** Put **DB + request path in the same `latency-domain` (OCI Frankfurt today)**; use GCP Spot for overflow work that is not on the critical path.
- **Sub‑10 ms almost always:** achievable for **hot-path** traffic that never leaves that domain—not for every possible cross-cloud hop.
