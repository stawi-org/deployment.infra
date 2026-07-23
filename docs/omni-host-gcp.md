# Omni host on GCP (stawi-timber)

## Why not Spot workers

Omni is the **management plane**. Spot preemption would take down Omni UI,
machine joins, and day-2 ops. The Omni host uses a **STANDARD** (non-Spot)
GCE VM. The Talos worker pack stays on Spot separately.

## Always Free shape

| Setting | Value | Notes |
|---|---|---|
| Account | `stawi-timber` | Repo SOPS auth |
| Machine | `e2-micro` | Always Free eligible |
| Region | `us-central1` | Free tier only in us-west1 / us-central1 / us-east1 |
| Disk | 30 GB `pd-standard` | Free tier includes 30 GB-months |
| Spot | **no** | `provisioning_model = STANDARD` |
| RAM | 1 GiB + **2 GiB swap** | Tight for Omni+Dex+nginx — upgrade to `e2-small` if OOM |

`europe-west9` (worker region) is **not** Always Free for e2-micro.

## Module

- `tofu/modules/omni-host-gcp` — VPC, static IP, firewall, Ubuntu 24.04 + cloud-init
- `tofu/layers/00-omni-server` — `omni_host_provider = "gcp"`

Shared docker-compose / Omni templates unchanged.

## Cutover Contabo → GCP (production)

Omni etcd restore uses the Contabo R2 backup prefix so machine pins can survive.

1. **Prereq:** `bootstrap-gcp-wif.sh` completed for stawi-timber (WIF, SA, firewall roles).
2. **Plan only (no cutover yet):**
   ```bash
   # In a branch: set omni_host_provider = "gcp" in terraform.tfvars
   gh workflow run tofu-omni-host.yml -f mode=plan
   ```
3. **Orphan Contabo from OpenTofu state** (keep the VPS hardware):
   ```text
   pre_apply_state_rm:
     module.omni_host_contabo[0].contabo_instance.this
     module.omni_host_contabo[0].null_resource.ensure_image
     # plus any other contabo-only addresses shown by plan destroy
   ```
   Use `tofu-omni-host` workflow_dispatch `pre_apply_state_rm` (whitespace-separated).
4. **Apply with provider=gcp** on `main` (merge + push or dispatch `mode=apply`).
5. **Verify:** SSH/console, `docker compose ps`, `https://cp.stawi.org` after DNS TTL.
6. **Stop Omni on Contabo** (prevent dual masters):
   ```bash
   # on contabo-bwire-node-3
   cd /opt/omni && docker compose down
   ```
7. **Contabo VPS → Talos worker** (required once Omni is healthy on GCP) — see below.

### Contabo `202727781` as Talos worker

Today that VPS is **only** the Omni Ubuntu host (`contabo-bwire-node-3`).
It is **excluded** from cluster inventory on purpose
(`tofu/shared/bootstrap/contabo-instance-ids.yaml`).

After Omni is on GCP and Contabo Omni is stopped:

| Step | Action |
|---|---|
| 1 | Confirm Omni healthy on GCP (`cp.stawi.org`, machines still listed). |
| 2 | Contabo Omni stack is **down** (step 6 above). |
| 3 | Add inventory entry under R2 `production/inventory/contabo/bwire/nodes.yaml` (or seed path) for `contabo-bwire-node-3` as **`role: worker`** with `provider_data.contabo_instance_id: "202727781"`. |
| 4 | Uncomment / keep the matching line in `tofu/shared/bootstrap/contabo-instance-ids.yaml` (worker, not omni-host). |
| 5 | Apply Contabo + Talos layers: `cluster-provision` `mode=infra` (or full). Layer `01-contabo-infra` will **reimage** the VPS to Talos (worker). |
| 6 | Wait for machine join in Omni → MachineClass `workers` (label `node.stawi.org/role=worker`). |
| 7 | Contabo stays `role-database=false` (CNPG must not schedule DBs there). |

Expected inventory shape (R2):

```yaml
nodes:
  contabo-bwire-node-3:
    role: worker
    product_id: <same product class as the VPS already has>
    region: EU
    provider_data:
      contabo_instance_id: "202727781"
```

Notes:

- Reimage **wipes** the disk (Ubuntu/Omni gone). Only do this after GCP Omni is verified.
- `role: worker` only — Kubernetes CP stays on OCI; Contabo is capacity, not etcd.
- Existing moves in `01-contabo-infra/moves.tf` already know the address `module.nodes["contabo-bwire-node-3"]`.

### Do not

- Put Omni on Spot worker instances
- Apply `provider=gcp` without state-rm of Contabo if you still need that VPS
- Reimage Contabo to Talos **before** Omni is live on GCP
- Expect free-tier e2-micro to be as comfortable as the Contabo VPS (monitor memory)

## Rollback

1. Set `omni_host_provider = "contabo"`
2. Re-import Contabo VPS id into state if orphaned
3. Re-point DNS (apply 00-omni-server)
4. Start docker compose on Contabo again

## Related

- Topology: [topology.md](topology.md)
- GCP workers (Spot): [gcp-onboard.md](gcp-onboard.md)
- Bootstrap IAM: `scripts/bootstrap-gcp-wif.sh`
