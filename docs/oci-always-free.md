# OCI fleet sizing + Always Free guardrails

This fleet runs one OCI tenancy per account in `tofu/shared/accounts.yaml`
(`oracle:` list). Plan-time checks in
`tofu/modules/oracle-account-infra/free-tier.tf` and inventory helpers in
`scripts/lib/oci_free_tier.py` enforce fleet targets and the free block
envelope.

## Fleet compute targets (per node)

| Role | OCPU | Memory | Notes |
|---|---|---|---|
| **worker** | **4** | **24 GB** | Uses monthly free A1 hours then PAYG |
| **controlplane** | **2** | **12 GB** | Same shape family; fits continuous free alone |

- Shape: `VM.Standard.A1.Flex` only
- At most **2** A1 VMs per tenancy

## Always Free block volume (hard)

Source: [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
(updated 2026-06-15).

| Resource | Limit |
|---|---|
| Block Volume (boot + data) | **200 GB** hard cap |
| **Operational buffer** | **4 GB** reserved — never provision into the ceiling |
| **Usable boot total** | **196 GB** per tenancy |
| Single-node default boot | **196 GB** |
| Two-node split | **98 + 98 GB** (even split of 196) |
| Object Storage | **20 GB** total (image buckets must stay pruned) |
| VCN | 2 |
| Continuous free A1 compute | 2 OCPU + 12 GB (informational; fleet workers exceed this) |

**Important:** Continuous free A1 is **2 OCPU / 12 GB**. Fleet workers at
**4/24** intentionally sit above that continuous envelope and will bill
after the monthly free OCPU-hours are consumed. Block storage must still
stay within the free 200 GB cap with a 4 GB buffer.

## Safe inventory shapes

Single worker (preferred for most accounts):

```yaml
nodes:
  oci-<account>-node-1:
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 4
    memory_gb: 24
    boot_volume_size_gb: 196
```

Control plane + worker in one tenancy (e.g. **bwire** — balanced HA):

Both nodes are **2 OCPU / 12 GB** so neither starves the other. Boot still
uses the free block envelope with a 4 GB buffer (98 + 98 = 196). Tenancy
compute total is 4 OCPU / 24 GB (above continuous free 2/12; uses free
monthly hours then may PAYG).

```yaml
nodes:
  oci-<account>-node-1:
    role: controlplane
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 98
  oci-<account>-node-2:
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 98
```

Two control planes (no worker on that tenancy):

```yaml
nodes:
  oci-<account>-node-1:
    role: controlplane
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 98
  oci-<account>-node-2:
    role: controlplane
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 98
```

Do **not** put omni-host on these free-block tenancies. Omni runs on Contabo
(`omni_host_provider = "contabo"`).

## Enforcement

| Layer | Behaviour |
|---|---|
| `oracle-account-infra` checks | Always: A1 shape, ≤2 nodes, boot sum ≤196, role ceilings (worker ≤4/24, CP ≤2/12). When `enforce_always_free=true`: also continuous free compute ≤2/12 |
| `var.enforce_always_free` (default `false`) | Continuous free compute gate; fleet default off so workers can be 4/24 |
| Default `boot_volume_size_gb` | 196 (single node usable max with 4 GB buffer) |
| `validate-oci-free-tier.py` | Inventory fleet-policy preflight / CI check |
| `reconcile-oci-free-tier.yml` | Rewrite inventory to role-based fleet packs |
| `audit-oci-live-free-tier.yml` | Live API audit; boot buffer hard-fail; continuous free compute is WARN |
| `ensure-oci-free-tier-capacity.yml` | Seed empty accounts with 1×4/24/196; reconcile sizes on existing inventory |
| `prune-oci-free-tier-violators.yml` | Terminate non-A1 / >2 nodes / over fleet per-node ceilings; optional orphan VCN cleanup |

### Operator loop

```bash
# 1. Inventory: fill empty tenancies + fix sizes to fleet targets
gh workflow run ensure-oci-free-tier-capacity.yml -f write=true -f confirm=ENSURE

# 2. Live: terminate true violators / orphan VCNs (not 4/24 workers)
gh workflow run prune-oci-free-tier-violators.yml -f write=true -f confirm=PRUNE

# 3. Provision / in-place resize (shape_config); boot size applies on reinstall only
gh workflow run tofu-apply.yml
# or single account:
# gh workflow run tofu-layer.yml -f layer=02-oracle-infra -f mode=apply -f account=<acct> -f environment=production

# 4. Join machines + verify
gh workflow run sync-cluster-template.yml
gh workflow run audit-oci-live-free-tier.yml
```

### Live audit

```bash
gh workflow run audit-oci-live-free-tier.yml
```

Or against one profile with the OCI CLI already configured:

```bash
PROFILE=bwire ACCOUNT=bwire \
  COMPARTMENT_OCID=ocid1.tenancy... TENANCY_OCID=ocid1.tenancy... \
  scripts/audit-oci-live-free-tier.sh
```

Free-tier tenancies allow at most **2 VCNs**. Orphan `cluster-vcn-*` leftovers from
recreates must be deleted (subnet → IGW → custom SL/RT → VCN) or the live audit fails.

### Service limit: `custom-image-count`

Talos boots from a **per-tenancy custom image**. If
`limits value list --name custom-image-count` returns **value=0**, image
import and node create will always fail with `QuotaExceeded` even when
zero custom images exist.

| Check | Healthy free tenancy | Blocked (e.g. ambetera 2026-07) |
|---|---|---|
| `custom-image-count` limit | typically **25** | **0** |
| `available` | > 0 | 0 |

**Fix (operator, OCI Console):** Governance → Limits, Quotas and Usage →
filter `custom-image-count` → Request increase to **≥ 2** in the tenancy
**home region**. Then:

```bash
gh workflow run sync-talos-images.yml -f force=true
gh workflow run tofu-layer.yml -f layer=02-oracle-infra -f mode=apply -f account=<acct> -f environment=production
gh workflow run sync-cluster-template.yml
```

`sync-talos-images` preflights this limit and fails the account matrix cell
with an explicit error when the limit is 0.

## Object Storage note

`02-oci-storage` keeps image/state/backup buckets in the **bwire**
tenancy. Always Free Object Storage is **20 GB**, not 200 GB. Keep
`sync-talos-images` prune policy (current + 1 prior schematic) so
custom-image archives do not fill the free quota.

## Resize safety

- **OCPU / memory**: `shape_config` updates in place (no disk wipe) when
  inventory changes and tofu apply runs.
- **Boot volume size**: `source_details` is in `lifecycle.ignore_changes`;
  declared boot size applies only on create / reinstall
  (`force_reinstall_generation` or image change). Existing 100 GB disks
  stay 100 GB until reinstall even if inventory says 196.
