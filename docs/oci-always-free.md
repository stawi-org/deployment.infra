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

## Object Storage note

`02-oci-storage` keeps image/state/backup buckets in the **bwire**
tenancy. Always Free Object Storage is **20 GB**, not 200 GB. Keep
`sync-talos-images` prune policy (current + 1 prior schematic) so
custom-image archives do not fill the free quota.
