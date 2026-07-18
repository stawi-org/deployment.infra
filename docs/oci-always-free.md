# OCI Always Free guardrails

This fleet runs one **Always Free** OCI tenancy per account in
`tofu/shared/accounts.yaml` (`oracle:` list). Plan-time checks and inventory
helpers refuse sizes that would exceed continuous free compute or free block
storage.

## Caps (home region, per tenancy)

Source: [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
(updated 2026-06-15).

| Resource | Always Free limit |
|---|---|
| Ampere A1 (`VM.Standard.A1.Flex`) | **2 OCPU + 12 GB memory** continuous (1,500 OCPU-hours + 9,000 GB-hours / month) |
| A1 instance count | At most **2** VMs sharing the OCPU/memory pool |
| Block Volume (boot + data) | **200 GB** hard; we use **≤196 GB** (4 GB buffer) |
| Object Storage | **20 GB** total (image buckets must stay pruned) |
| VCN | 2 |

**Important:** Before June 2026 many guides treated free A1 as **4 OCPU / 24 GB**.
That is no longer continuous free. Sizing at 4/24 will bill (PAYG) after free
monthly hours or fail free-only tenancies.

## Safe inventory shapes

Single worker (preferred for most accounts):

```yaml
nodes:
  oci-<account>-node-1:
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 196
```

Two nodes (CP + worker, or 2× CP) — split the free pool:

```yaml
nodes:
  oci-<account>-node-1:
    role: controlplane
    shape: VM.Standard.A1.Flex
    ocpus: 1
    memory_gb: 6
    boot_volume_size_gb: 98
  oci-<account>-node-2:
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 1
    memory_gb: 6
    boot_volume_size_gb: 98
```

Do **not** put omni-host on these free tenancies. Omni runs on Contabo.

## Enforcement

| Layer | Behaviour |
|---|---|
| `oracle-account-infra` checks | Fail plan when sum(ocpus)>2, sum(memory)>12, boot>196, >2 nodes, non-A1 |
| `var.enforce_always_free` (default `true`) | Continuous free compute gate |
| Default boot | 196 solo / 98+98 two-node (4 GB free buffer) |
| `validate-oci-free-tier.py` | Inventory preflight |
| `ensure-oci-free-tier-capacity.yml` | Seed empty with 2/12/196; reconcile existing to free packs |
| `audit-oci-live-free-tier.yml` | Live API audit (hard fail on free overage) |
| `prune-oci-free-tier-violators.yml` | Terminate live VMs outside free envelope |

### Operator loop

```bash
gh workflow run ensure-oci-free-tier-capacity.yml -f write=true -f confirm=ENSURE
gh workflow run tofu-apply.yml   # or per-account tofu-layer 02-oracle-infra apply
gh workflow run audit-oci-live-free-tier.yml
```

### Service limit: `custom-image-count`

Talos needs a per-tenancy custom image. If `custom-image-count` is 0, raise
import fails. Raise to ≥2 in the Console (home region), then
`sync-talos-images` + tofu apply.

## Resize safety

- **OCPU / memory**: in-place via `shape_config` (no disk wipe).
- **Boot size**: `source_details` ignore_changes — declared boot applies on
  create/reinstall only.
