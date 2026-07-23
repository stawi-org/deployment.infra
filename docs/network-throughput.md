# Multi-site mesh: high throughput first

**Design principle:** the cluster is one encrypted fabric. Any pod may talk to
any pod on any provider. Optimization target is **sustained goodput and
resilience under WAN RTT/jitter/loss**, not forcing every workload into one
region.

Locality labels (`latency-domain`, topology keys) remain available for
*optional* affinity when an app wants them. They are **not** required for the
platform to be considered healthy.

## Topology (what “everywhere” means)

| Site | Role | Notes |
|---|---|---|
| Contabo EU | Stable workers / some CP capacity | Public dual-stack where available |
| OCI `eu-frankfurt-1` | Workers + **stateful DBs** | Always Free packing; `db-eligible` stays off GCP |
| GCP `europe-west9` (Paris) | Spot general workers | Elastic; same mesh as everyone else |
| On-prem | Optional workers | Manual Talos apply |

Connectivity path:

```
Pod → Flannel (pod overlay) → node public path
         ↕
    KubeSpan WireGuard mesh (all nodes peers)
```

## Throughput-oriented infrastructure (this repo)

| Knob | Setting | Why |
|---|---|---|
| KubeSpan | enabled, full mesh | Seamless interconnect without per-cloud VPNs |
| `advertiseKubernetesNetworks` | **false** | Avoid default-route blackholes; keep mesh for cluster traffic |
| KubeSpan **MTU 1380** | under path 1500 | Avoid fragmentation (kills throughput more than size) |
| `allowDownPeerBypass` | **true** | Survive partial peer/discovery failures |
| Flannel public-ip-overwrite | OCI + GCP | Correct underlays under 1:1 NAT |
| UDP **51820** / **4789** | open | WireGuard + VXLAN between sites |
| TCP **BBR** + **fq** | machine sysctls | High BDP multi-cloud (loss-tolerant vs cubic) |
| Large TCP windows | up to 128 MiB | Fill pipes Contabo↔OCI↔GCP |
| `tcp_mtu_probing` | 1 | Adapt if path MTU is lower |
| `tcp_slow_start_after_idle` | 0 | Keep long-lived streams hot |
| Topology + `latency-domain` labels | on all nodes | Optional affinity only |
| Omni twin hygiene | post-apply | Ghost machines must not clog the mesh |

## What “robust high throughput” means in practice

1. **Any→any connectivity** always works (KubeSpan + discovery).
2. **Bulk and many parallel streams** use BBR/large windows so WAN RTT does not
   collapse goodput the way cubic often does under loss.
3. **No single site is required** for workers to participate: GCP Spot, OCI, and
   Contabo are first-class mesh members.
4. **Stateful DBs stay on OCI** for capacity/economics/Spot risk—not because the
   network cannot reach them from Paris (it can and should, at full mesh rate).
5. **Loss avoidance &gt; micro-optimization of RTT:** wrong MTU, NAT mistakes, or
   ghost peers hurt throughput more than an extra few milliseconds.

## Application guidance (deployment.manifest)

| Pattern | Recommendation |
|---|---|
| Default | Schedule freely; assume mesh is good enough |
| DB primary | Prefer OCI (`db-eligible` / provider labels)—data plane risk, not mesh |
| Fan-out workers | GCP Spot + OCI + Contabo all fine |
| Optional | Soft affinity to `latency-domain` only if profiling shows benefit |
| Avoid | Assuming cross-site RTT is LAN; design retries/timeouts for WAN |

## SLOs (throughput-centric)

| Metric | Target |
|---|---|
| Mesh reachability | All Ready nodes have working KubeSpan peers (no permanent blackholes) |
| Cross-site TCP goodput | Majority of path capacity under load (BBR), not cubic collapse |
| Request success under multi-site load | Prefer availability + throughput; p99 latency is secondary |
| Recovery | Spot STOP/start + Omni hygiene keep the mesh membership clean |

Latency remains measurable and improvable via labels when needed; it is not the
primary control plane for placement.

## Verification

```bash
# Membership + topology labels (optional for apps)
kubectl get nodes -L node.stawi.org/provider,node.stawi.org/latency-domain

# From a pod: multi-stream iperf3 or similar to a pod on another provider
# Expect stable multi-stream goodput; single-stream will still be RTT-bound.

# Talos: confirm congestion control after apply
# talosctl read /proc/sys/net/ipv4/tcp_congestion_control  → bbr
```

## Related

- [docs/topology.md](topology.md) — ownership modes, etcd boundary
- [docs/gcp-lifecycle.md](gcp-lifecycle.md) — Spot STOP, ghost purge
- [docs/network-latency.md](network-latency.md) — optional co-location notes (secondary)
