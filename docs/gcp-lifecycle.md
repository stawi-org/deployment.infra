# GCP workers — robust lifecycle (idempotency + no Omni ghosts)

This document is the contract for a **streamlined, extensible, fast, and
idempotent** GCP worker path. Desired state is OpenTofu; Omni hygiene is
automatic after every successful apply.

## Goals

| Goal | How |
|---|---|
| Robust | Spot STOP (not DELETE), stable hostnames, identity pins |
| Streamlined | No seed/catalog Python; defaults in OpenTofu |
| Fast day-2 | `mode=infra` = tofu-apply only |
| Extensible | Per-project accounts + R2 inventory overrides |
| Idempotent | Re-apply is no-op; ghosts purged after apply |
| No ghost Omni nodes | Matcher never labels disconnected twins; post-apply cleanup |

## Control plane (who owns what)

```
bootstrap-gcp-wif.sh     once: WIF + SOPS auth PR
        │
        ▼
accounts.yaml + auth.yaml
        │
        ▼
cluster-provision / tofu-apply
  ├─ (full only) sync-talos-images   # Omni media → GCE family stawi-talos
  ├─ 02-gcp-infra                    # OpenTofu: VPC + VMs + R2 inventory
  ├─ 03-talos                        # labels + patches (connected only)
  ├─ 04-dns
  └─ omni-hygiene                    # delete dead twins + pin live UUIDs
```

## Idempotency matrix

| Event | Instance | Omni Machine UUID | Labels / patches | Inventory pin |
|---|---|---|---|---|
| Re-apply, no change | no-op | stable | no-op apply | preserved |
| Spot preemption | **STOP** (disk kept) | same after restart | same | preserved (`gce_unique_id` unchanged) |
| Next apply after STOP | `desired_status=RUNNING` starts VM | reconnects | re-sync if needed | preserved |
| Force reinstall | destroy + create | **new** UUID | wait for connected twin | pin **cleared** then re-pinned by hygiene |
| Add node (inventory) | create | new | poll until connected | pin after hygiene |
| Remove node | destroy | becomes disconnected | — | entry removed; hygiene drops twin if live hostname gone |

## Why Spot uses STOP, not DELETE

`instance_termination_action = STOP` (GCP default for Spot):

- Boot disk and Talos state survive preemption
- SideroLink identity usually survives → **same Omni UUID**
- Avoids the DELETE path that minted a new machine every preemption and left a disconnected twin bound to the cluster

`desired_status = "RUNNING"` makes the next OpenTofu apply start stopped Spot VMs when capacity exists (idempotent recovery).

Force reinstall still destroys the instance (new `gce_unique_id`); the nodes-writer **drops** `omni_machine_id` when that id changes so we never pin a ghost.

## Omni identity rules (no ghosts)

Shared matcher: `scripts/lib/omni_machine_match.py`

| Caller | `require_connected` | Behavior |
|---|---|---|
| MachineLabels / ConfigPatches | **true** | Never targets a disconnected machine; polls until live |
| Inventory pin reconcile | false | May hold pin while offline if no twin |

After every successful `tofu-apply` → `03-talos`:

1. **omni-cleanup-dead-twins** — for each hostname with a disconnected cluster member **and** a connected twin, purge the dead UUID (never deletes connected)
2. **reconcile-omni-machine-ids** — write live UUIDs to R2

## Day-2 operator path (fast)

```bash
# Scale / change inventory in R2, then:
gh workflow run cluster-provision.yml -f mode=infra
```

That is OpenTofu apply + Omni hygiene only. No image rebuild.

## First project / image refresh

```bash
./scripts/bootstrap-gcp-wif.sh --project … --gh-profile …
# merge PR → onboard-gcp runs mode=full once

# Later schematic / Talos bump only:
gh workflow run cluster-provision.yml -f mode=images
# or mode=full with force_image_sync=true when intentional
```

## Extension points

| Add | Do |
|---|---|
| Another GCP project | bootstrap + merge; OpenTofu defaults apply |
| Custom node count/size | Edit R2 `nodes.yaml` → `mode=infra` |
| Standard (non-Spot) node | `preemptible: false` on that inventory entry |
| New provider | Same `provider_data.omni_machine_id` + matcher; wire hygiene already global |

## Failure modes

| Symptom | Fix |
|---|---|
| Labels missing on new node | Wait for SideroLink; re-run `mode=infra` (polls up to 15m) |
| Disconnected twin in Omni UI | Should be auto-purged post-apply; or `omni-cleanup-dead-twins` |
| Spot stuck TERMINATED | Next apply starts it; or start manually if capacity |
| PermissionDenied on ClusterMachines | Omni SA must be **Admin** (see omni-machine-identity.md) |
