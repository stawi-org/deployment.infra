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
7. **Contabo as Talos worker (optional later):** reimage the orphaned VPS via Contabo inventory as a worker node (separate change).

### Do not

- Put Omni on Spot worker instances
- Apply `provider=gcp` without state-rm of Contabo if you still need that VPS
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
