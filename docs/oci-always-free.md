# OCI Always Free guardrails

This fleet runs one **Always Free** OCI tenancy per account in
`tofu/shared/accounts.yaml` (`oracle:` list). Plan-time checks in
`tofu/modules/oracle-account-infra/free-tier.tf` refuse to apply
inventory that would exceed the free envelope.

## Caps (home region, per tenancy)

Source: [Always Free Resources](https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm)
(updated 2026-06-15).

| Resource | Always Free limit |
|---|---|
| Ampere A1 (`VM.Standard.A1.Flex`) | **2 OCPU + 12 GB memory** continuous (1,500 OCPU-hours + 9,000 GB-hours / month) |
| A1 instance count | At most **2** VMs sharing the OCPU/memory pool |
| Block Volume (boot + data) | **200 GB** total |
| Object Storage | **20 GB** total (image buckets must stay pruned) |
| VCN | 2 |
| Bastion | Free |
| Outbound data | 10 TB / month |

**Important:** Before June 2026 many guides (and this repo) treated the
A1 free pool as **4 OCPU / 24 GB**. That is no longer correct. Sizing
at 4/24 will either bill (PAYG) or fail free-only tenancies.

## Safe inventory shapes

Single worker (preferred for most accounts):

```yaml
nodes:
  oci-<account>-node-1:
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 2
    memory_gb: 12
    boot_volume_size_gb: 100
```

Two small VMs in one tenancy (only if you truly need two):

```yaml
nodes:
  oci-<account>-node-1:
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 1
    memory_gb: 6
    boot_volume_size_gb: 100
  oci-<account>-node-2:
    role: worker
    shape: VM.Standard.A1.Flex
    ocpus: 1
    memory_gb: 6
    boot_volume_size_gb: 100
```

Do **not** put omni-host and a 2/12 cluster node on the same free
tenancy — that is 4 OCPU / 24 GB total. Omni currently runs on Contabo
(`omni_host_provider = "contabo"`).

## Enforcement

| Layer | Behaviour |
|---|---|
| `oracle-account-infra` `check` blocks | Fail plan when sum(ocpus)>2, sum(memory)>12, sum(boot)>200, >2 nodes, or non-A1 shape |
| `var.enforce_always_free` (default `true`) | Pass `false` only for intentionally paid tenancies |
| Default `boot_volume_size_gb` | 100 (was 180) |
| `validate-oci-free-tier.py` | Inventory (R2 `nodes.yaml`) preflight / CI check |
| `reconcile-oci-free-tier.yml` | Rewrite inventory shapes to free-tier-safe packs |
| `audit-oci-live-free-tier.yml` | Live API audit per tenancy (instances, volumes, VCNs, object storage, reserved IPs, LBs, ADBs) |
| `ensure-oci-free-tier-capacity.yml` | Seed empty accounts with 1×2/12/100; reconcile sizes on existing inventory |
| `prune-oci-free-tier-violators.yml` | Terminate live VMs that exceed free caps; optional orphan VCN cleanup |

### Operator loop (keep free capacity filled and clean)

```bash
# 1. Inventory: fill empty tenancies + fix oversized declared sizes
gh workflow run ensure-oci-free-tier-capacity.yml -f write=true -f confirm=ENSURE

# 2. Live: terminate free-tier violators / orphan VCNs
gh workflow run prune-oci-free-tier-violators.yml -f write=true -f confirm=PRUNE

# 3. Provision any new inventory nodes
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
