# Locality notes (optional, secondary)

**Primary design:** [docs/network-throughput.md](network-throughput.md) —
high throughput multi-site mesh first.

This page only covers **optional** co-location when an application
profile benefits from lower RTT. The platform does **not** require
locality for correctness or baseline performance.

## When locality helps

| Situation | Optional action |
|---|---|
| Chatty API + DB with tiny queries | Soft affinity to same `topology.kubernetes.io/region` / zone |
| Want topology-aware Services | Use topology keys already on nodes |
| Edge close to users | Prefer nearby region *if* replicas exist there |

## When to ignore locality

| Situation | Action |
|---|---|
| Batch, async, fan-out | Schedule anywhere on the mesh |
| Need capacity | Use GCP Spot + OCI + Contabo without affinity |
| DB policy | Keep DBs on OCI for operational reasons; apps remote-call over mesh |

## Labels available

See [node-labels.md](node-labels.md) — especially `role-database` + `provider` for CNPG,
and `topology.kubernetes.io/*` for optional co-location.

Cross-site RTT (e.g. Paris↔Frankfurt) often exceeds 10 ms by physics. That is
expected; the mesh is tuned so **bandwidth still flows** under that RTT (BBR,
windows, MTU). See network-throughput.md.
