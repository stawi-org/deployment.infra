# Omni machine identity consistency

Omni assigns each SideroLink-connected Talos node a **Machine UUID**.
That UUID is the join/bind key for MachineSets, MachineLabels, and
per-node ConfigPatches. Hostname is only a convenience label.

## Goals

1. **Stable pins** in inventory: `provider_data.omni_machine_id`
2. **Identity-first matching** for labels and patches
3. **Safe twin recovery** when a host re-registers under a new UUID
4. **Minimal disruption**: tofu rewrites must not erase the pin

## Matching priority

Shared library: `scripts/lib/omni_machine_match.py`

| Order | Rule |
|---|---|
| 1 | Prefer inventory `omni_machine_id` if that UUID still exists and is **connected** |
| 2 | If preferred UUID is **disconnected** but a **connected hostname twin** exists → use twin |
| 3 | Else hostname match (prefer connected) |
| 4 | Else IPv4 match (prefer connected) |

**Labeling / patches** pass `--require-connected`: a disconnected preferred
pin is **never** returned (avoids applying MachineLabels to ghost twins after
Spot recreate or force reinstall). Inventory pin reconcile may still hold an
offline pin when no twin exists (`require_connected=false`).

Used by:

- `tofu/layers/03-talos/scripts/sync-machine-label.sh` (`require_connected`)
- `tofu/layers/03-talos/scripts/apply-per-node-patches.sh` (`require_connected`)
- `scripts/reconcile-omni-machine-ids.py`

## Persist pins (inventory)

```bash
# Dry-run
gh workflow run reconcile-omni-machine-ids.yml

# Write provider_data.omni_machine_id to R2
gh workflow run reconcile-omni-machine-ids.yml -f write=true -f confirm=RECONCILE
```

Local equivalent:

```bash
omnictl get machinestatus -o json | jq -cs flatten > /tmp/ms.json
aws s3 sync s3://cluster-tofu-state/production/inventory/ /tmp/inventory/ ...
python3 scripts/reconcile-omni-machine-ids.py \
  --inventory-dir /tmp/inventory --machines-file /tmp/ms.json --write
```

## Preserve pins across tofu apply

`nodes-writer.tf` on oracle / contabo / onprem / gcp **merges** observed
`provider_data` over existing keys so `omni_machine_id` survives steady
applies. GCP also stores `gce_unique_id` and **clears** the Omni pin when
that id changes (destroy/create), so a force reinstall never pins a ghost.

## Twin / rebind recovery

When free-tier resize, soft-reset, or force reinstall produce a
**disconnected cluster-bound UUID** and a **connected twin** under the
same hostname (ghost etcd members / stage-1 control planes):

```bash
# Preferred: discover + strip finalizers + delete dead twins + relabel + pin
gh workflow run omni-cleanup-dead-twins.yml -f dry_run=true
gh workflow run omni-cleanup-dead-twins.yml -f dry_run=false -f confirm=CLEANUP

# Or: rebind (same purge + label path, no pin write)
gh workflow run omni-rebind-disconnected-machines.yml -f confirm=REBIND -f dry_run=false

# Pin live UUIDs into inventory (cleanup does this when write_pins=true)
gh workflow run reconcile-omni-machine-ids.yml -f write=true -f confirm=RECONCILE
```

**Automatic:** every successful `tofu-apply` runs cleanup after `03-talos`
(`omni-hygiene`: dry_run=false, auto_confirm, write_pins) so operator
memory is not required for Spot/GCP recreate ghosts.

**Never** manually create MachineSetNodes on automated MachineSets —
use role labels + MachineClass only. After purge, if control planes
stay at stage 1, soft-reset live CP OCI instances (`oci-soft-reset-instances`)
then re-check `cluster-health`.

### Service account privileges

`OMNI_SERVICE_ACCOUNT_KEY` must be **Admin** (not Operator-only) for
twin recovery. Operator can tear down Links/Machines but gets
`PermissionDenied: only read access is permitted` on
`ClusterMachines` and related cluster-scoped status resources. Ghost
control-plane ClusterMachines left behind block etcd bootstrap
(quorum waits on disconnected members).

If cleanup logs show PermissionDenied on `clustermachines/*`:

1. Rotate the GitHub secret to an **Admin** Omni service-account key, or
2. In the Omni UI (Admin user), delete the disconnected ClusterMachine
   rows for the dead UUIDs, then re-run cleanup + soft-reset CPs.

### Finalizer patches

When stripping stuck resources, **only** delete
`metadata.finalizers`. Broader patches (`version` / `owner` / `phase`)
are rejected by Omni and leave finalizers intact.

## What operators should avoid

| Prefer | Avoid |
|---|---|
| In-place `shape_config` resize | Destroy + create for routine size changes |
| Soft OCI `RESET` | Re-image / wipe boot for recovery |
| Matching via `omni_machine_id` | Hostname-only when twins may exist |

## Extension points

| Extension | How |
|---|---|
| New provider inventory | Same `provider_data.omni_machine_id` field; merge in that provider’s nodes-writer |
| New matcher rule | Edit `omni_machine_match.py` + unit tests only |
| Join-time role labels | Bake `node.stawi.org/role` into schematic/kernel cmdline (see TODO in `tofu/shared/clusters/main.yaml`) so MachineClass binds without post-registration sync |
| Auto-reconcile after apply | Call `reconcile-omni-machine-ids` from `workflow_run` of `tofu-apply` / rebind |

## Inventory schema (provider_data)

```yaml
nodes:
  oci-bwire-node-1:
    role: controlplane
    provider_data:
      oci_instance_ocid: ocid1.instance...
      ipv4: "x.x.x.x"
      omni_machine_id: "5de2c07d-...."   # preferred Omni UUID pin
      status: running
```
