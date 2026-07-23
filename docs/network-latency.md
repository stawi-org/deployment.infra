# Locality notes (optional, secondary)

**Primary design:** [docs/network-throughput.md](network-throughput.md) —
high throughput multi-site mesh first.

This page only covers **optional** co-location when an application
profile benefits from lower RTT. The platform does **not** require
locality for correctness or baseline performance.

## When locality helps

| Situation | Optional action |
|---|---|
| Chatty API + DB with tiny queries | Soft affinity to same `node.stawi.org/latency-domain` |
| Want topology-aware Services | Use topology keys already on nodes |
| Edge close to users | Prefer backends in nearer domain *if* replicas exist there |

## When to ignore locality

| Situation | Action |
|---|---|
| Batch, async, fan-out | Schedule anywhere on the mesh |
| Need capacity | Use GCP Spot + OCI + Contabo without affinity |
| DB policy | Keep DBs on OCI for operational reasons; apps remote-call over mesh |

## Labels available

- `topology.kubernetes.io/region` / `zone`
- `node.stawi.org/latency-domain` (`oci-eu-frankfurt-1`, `gcp-europe-west9`, `contabo-eu`)
- `node.stawi.org/provider`, `node.stawi.org/db-eligible`

Cross-site RTT (e.g. Paris↔Frankfurt) often exceeds 10 ms by physics. That is
expected; the mesh is tuned so **bandwidth still flows** under that RTT (BBR,
windows, MTU). See network-throughput.md.
