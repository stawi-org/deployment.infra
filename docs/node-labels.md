# Node label contract (shared with deployment.manifests)

Labels set by this repo’s node modules must match what Flux workloads
already select on. **Do not invent parallel keys** for the same policy.

## Used by CNPG (authoritative)

From `deployment.manifests` CNPG `Cluster` affinity (e.g. `namespaces/*/cluster/cluster.yaml`):

```yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - key: node.stawi.org/role-database
            operator: In
            values: ["true"]
          - key: node.stawi.org/provider
            operator: NotIn
            values: [contabo]
```

| Label | Meaning | Infra sets |
|---|---|---|
| `node.stawi.org/role-database` | CNPG may schedule here | **`true` on OCI**; **`false` on Contabo + GCP** (forced, inventory cannot enable DB on GCP/Contabo) |
| `node.stawi.org/provider` | cloud ownership | `oracle` / `contabo` / `gcp` / `onprem` |

Policy: **Postgres off Contabo** (and not on GCP Spot). See manifests
`docs/capacity/hot-db-p99-sla.md`.

## Used by other manifests

| Label | Consumer |
|---|---|
| `node.stawi.org/external-load-balancer=true` | Envoy Gateway DaemonSet, DNS `prod.*` |
| `node.stawi.org/role-email=true` | Postfix DaemonSet |
| `topology.kubernetes.io/region` / `zone` | Topology spread, PreferSameZone poolers |
| `node.stawi.org/role` | Omni MachineClass (`controlplane` / `worker`) — Omni Machine labels, also on K8s Node via Talos |
| `node.stawi.org/name` | Per-node ConfigPatches |

## Infra-only / informational

| Label | Meaning |
|---|---|
| `node.stawi.org/account` | Inventory account key |
| `node.stawi.org/spot` | GCP Spot vs standard |
| `node.stawi.org/capacity-class` | Optional inventory (`spot`, etc.) |

## Not used (do not reintroduce)

| Label | Why removed |
|---|---|
| `node.stawi.org/db-eligible` | Reinvented CNPG’s `role-database` |
| Ad-hoc affinity keys | Prefer the keys already in deployment.manifests |

## Merge order

Module-derived labels **win** over inventory for forced policy keys
(`provider`, `role-database`, topology). Operators set optional labels
(e.g. `external-load-balancer`, `role-email`) in R2 inventory; those
merge under forced keys.
