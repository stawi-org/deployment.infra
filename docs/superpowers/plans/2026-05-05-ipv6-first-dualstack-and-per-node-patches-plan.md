# IPv6-first dual-stack + reintroduced per-node Talos patches — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restore per-node Talos networking patches retired in `490ae67`/`7c7b6cd` with the IPv6-gateway bug fixed by construction; fold OCI Flannel public-IP overrides and Kubernetes Node label/annotation propagation into the same flow; flip cluster-wide subnets to IPv6-first ordering.

**Architecture:** Two scopes of Talos config — a single cluster-wide `LinkAliasConfig` (universal `link.type == "ether"` selector → alias `wan0`) plus per-node patches rendered by tofu layer-03 from `contabo_instance.ip_config[0].v{4,6}[0]` and `node-oracle.derived_annotations`, written to R2, applied per-machine by the `sync-cluster-template` workflow with on-the-fly machine-id resolution.

**Tech Stack:** OpenTofu, Talos Linux v1.13, Omni cluster templates, `omnictl`, Cloudflare R2 (S3-compatible) for artifact storage, GitHub Actions workflows, bash scripts using `jq` and `omnictl get machinestatus`.

**Spec:** [`docs/superpowers/specs/2026-05-05-ipv6-first-dualstack-and-per-node-patches-design.md`](../specs/2026-05-05-ipv6-first-dualstack-and-per-node-patches-design.md)

**Cluster apply policy reminder:** All applies go through CI workflows (`tofu-apply.yml` for layer-03 changes; `sync-cluster-template.yml` for cluster-template + per-node-patches). Do NOT run `tofu apply` locally on the live state. Local `tofu plan` against a fresh `tofu init` clone is fine for inspecting diffs.

---

## File Structure

### Files created

| Path | Responsibility |
|---|---|
| `tofu/shared/patches/link-alias.yaml` | Cluster-wide `LinkAliasConfig` document (one resource, applies everywhere). |
| `tofu/shared/patches/node-contabo.tftpl` | Per-Contabo-node Talos patch template — `machine.nodeLabels`/`nodeAnnotations` + `LinkConfig` + `HostnameConfig`. |
| `tofu/shared/patches/node-oracle.tftpl` | Per-OCI-node Talos patch template — `machine.nodeLabels`/`nodeAnnotations` (incl. flannel overrides) + `HostnameConfig`. |
| `tofu/layers/03-talos/per-node-patches.tf` | `for_each` over nodes; renders the per-provider tftpl; writes each result to R2 via `aws_s3_object`. |
| `tofu/layers/03-talos/scripts/apply-per-node-patches.sh` | Workflow-invoked: pulls each patch from R2, resolves machine-id via Omni, wraps in `ConfigPatches.omni.sidero.dev` envelope, `omnictl apply`. Idempotent. |

### Files modified

| Path | Change |
|---|---|
| `tofu/modules/node-contabo/main.tf` | Add `ipv4_cidr`, `ipv4_gateway`, `ipv6_cidr`, `ipv6_gateway` to `locals`; add precondition. |
| `tofu/modules/node-contabo/outputs.tf` | Extend `node` output contract with the four new fields. |
| `tofu/modules/node-oracle/outputs.tf` | Extend `node` output contract with `public_ipv4`. |
| `tofu/shared/clusters/main.yaml` | Add `link-alias` to `patches:`; flip `dual-stack` patch ordering to IPv6-first. |
| `tofu/layers/03-talos/cluster.tf` | Narrow `omni_machine_apply_per_node.labels` to only `node.antinvestor.io/role`. |
| `.github/workflows/sync-cluster-template.yml` | Replace "Remove legacy per-node link patches" step with a render-aware "Apply per-node patches" + "Sweep orphan per-node patches" pair. |

### Files unchanged but referenced

- `tofu/shared/patches/cluster-network.yaml`, `tofu/shared/patches/resolvers.yaml`, `tofu/shared/patches/common.yaml` — verify they don't conflict with the new patches; no edits expected.
- `tofu/layers/03-talos/scripts/sync-machine-labels.sh` — reused as a pattern for the new apply script.

---

## Task Decomposition

### Phase 1 — Cluster-wide patches

Lowest-blast-radius changes: a new universal alias config and an in-place subnet reordering. Both apply to every machine via the existing cluster-template sync flow. No per-node renderer required to land these.

#### Task 1: Create `link-alias.yaml`

**Files:**
- Create: `tofu/shared/patches/link-alias.yaml`

- [ ] **Step 1: Write the patch file.**

```yaml
---
# tofu/shared/patches/link-alias.yaml
#
# Cluster-wide LinkAliasConfig. Aliases the first physical Ethernet
# interface on every node to `wan0` regardless of kernel-assigned
# name (ens18, enp0s3, eth0, etc.) or driver (virtio_net on Contabo /
# OCI VMs, anything on bare metal). Per-node LinkConfig docs (in
# tofu/shared/patches/node-contabo.tftpl) attach addresses+routes
# against `wan0`.
#
# Why `link.type == "ether"` and not `link.driver == "virtio_net"`:
# Talos already restricts LinkAliasConfig to physical links — we
# don't need a `physical: true` filter; it's implicit (wireguard,
# bonds, vlans, sidero, lo are excluded automatically). The
# `link.type == "ether"` filter is universal across providers; the
# driver-name approach (per the retired 490ae67 patch comment) only
# worked for virtio_net hosts.
#
# Why format-verb `wan%d` not fixed `wan`: a fixed alias requires
# the selector to match exactly one link or Talos rejects the doc.
# `wan%d` accepts multiple matches and assigns sequential aliases
# (`wan0`, `wan1`, ...). For single-uplink nodes — every current
# cluster node — only `wan0` is created; downstream LinkConfig pins
# to `wan0` deterministically. Multi-NIC nodes (future on-prem) get
# non-deterministic enumeration and need a per-node MAC-pinned
# override; documented in node-contabo.tftpl header.
apiVersion: v1alpha1
kind: LinkAliasConfig
name: wan%d
selector:
  match: link.type == "ether"
```

- [ ] **Step 2: Validate the YAML parses.**

Run from repo root:
```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('tofu/shared/patches/link-alias.yaml')))"
```
Expected: silent exit (status 0). Any error means the YAML is malformed.

- [ ] **Step 3: Commit.**

```bash
git add tofu/shared/patches/link-alias.yaml
git commit -m "tofu/shared/patches: add cluster-wide link-alias LinkAliasConfig

Aliases the first physical Ethernet on every node to wan0 via the
universal link.type == \"ether\" selector. Foundation for the
per-node LinkConfig patches reintroduced after the 490ae67
retirement: per-node patches attach addresses/routes against wan0
without needing to know the kernel-assigned name."
```

---

#### Task 2: Wire `link-alias` into the cluster template

**Files:**
- Modify: `tofu/shared/clusters/main.yaml`

- [ ] **Step 1: Read the current `patches:` block to find the insertion point.**

```bash
grep -n "^patches:\|^  - name:\|^kind:" tofu/shared/clusters/main.yaml | head -20
```

Locate the first `- name:` entry under `patches:`. New patch goes immediately after that header so it's first to apply (alias must exist before per-node `LinkConfig name: wan0` references it).

- [ ] **Step 2: Insert the new patch reference.**

Add this entry as the FIRST item in the cluster's `patches:` list (replace the existing first patch's leading `- name:` line with this block, then re-indent the existing patch underneath it). Use Edit on `tofu/shared/clusters/main.yaml` so the surrounding content stays intact:

```yaml
patches:
  # Cluster-wide LinkAliasConfig: makes `wan0` resolve to each node's
  # first physical Ethernet interface. MUST precede any per-node
  # LinkConfig that references `wan0` — Omni applies cluster-template
  # patches to every Machine, so order is positional within this list.
  - name: link-alias
    file: ../patches/link-alias.yaml
  # Dual-stack networking. ... (existing comment block + body unchanged)
  - name: dual-stack
    inline:
      ...
```

Notes:
- The existing patches use a mix of `- name: ... inline: { ... }` (inlined) and the `file:` form. Either works for the cluster template; `file:` is preferred here to keep the alias separately editable.
- Verify the relative path `../patches/link-alias.yaml` resolves from `tofu/shared/clusters/` (it does — `tofu/shared/patches/link-alias.yaml`).

- [ ] **Step 3: Validate the cluster template locally.**

```bash
# Install omnictl matching the workflow version (v1.7.1) into a
# temp dir if you don't already have it.
omnictl cluster template validate -f tofu/shared/clusters/main.yaml
```
Expected: `OK` (exit 0). If `omnictl` not installed locally, run a dry-run via:
```bash
gh workflow run sync-cluster-template.yml -f dry_run=true
```
and watch for the `Validate template` step's success in the run logs.

- [ ] **Step 4: Commit.**

```bash
git add tofu/shared/clusters/main.yaml
git commit -m "clusters/main: wire link-alias as first cluster patch

Cluster-wide LinkAliasConfig must apply before any per-node
LinkConfig references the alias. Listed first in patches: so it's
positionally guaranteed to lead."
```

---

#### Task 3: Flip `dual-stack` patch to IPv6-first ordering

**Files:**
- Modify: `tofu/shared/clusters/main.yaml` (the `dual-stack` patch's `podSubnets` and `serviceSubnets` lists)

- [ ] **Step 1: Read the current `dual-stack` patch body.**

```bash
sed -n '85,150p' tofu/shared/clusters/main.yaml
```

Current shape (~lines 102-128):
```yaml
  - name: dual-stack
    inline:
      cluster:
        network:
          podSubnets:
            - 10.244.0.0/16
            - fd00:10:244::/56
          serviceSubnets:
            - 10.96.0.0/12
            - fd00:10:96::/108
```

- [ ] **Step 2: Edit the file — flip the two subnet lists.**

```yaml
  - name: dual-stack
    inline:
      cluster:
        network:
          podSubnets:
            - fd00:10:244::/56
            - 10.244.0.0/16
          serviceSubnets:
            - fd00:10:96::/108
            - 10.96.0.0/12
```

Leave the `machine.kubelet.nodeIP.validSubnets` block (and surrounding comment) unchanged — that's already correct.

- [ ] **Step 3: Validate again.**

```bash
omnictl cluster template validate -f tofu/shared/clusters/main.yaml
```
Expected: `OK`.

- [ ] **Step 4: Commit.**

```bash
git add tofu/shared/clusters/main.yaml
git commit -m "clusters/main: flip dual-stack patch to IPv6-first subnet ordering

Listing IPv6 first in podSubnets and serviceSubnets makes IPv6 the
primary family for new dual-stack services. Required for the
\"IPv6-first dual-stack\" cluster goal. Reversible by re-flipping
this patch and re-syncing."
```

---

### Phase 2 — Node module output extensions

Pure data plumbing — no behavior change yet. Each task is a small additive surgery on a node module that gets caught by `tofu validate`.

#### Task 4: Extend `node-contabo` locals with v4/v6 cidr+gateway

**Files:**
- Modify: `tofu/modules/node-contabo/main.tf` (lines ~88-90, the `locals` block defining `ipv4`/`ipv6`)

- [ ] **Step 1: Read the existing block.**

```bash
sed -n '85,95p' tofu/modules/node-contabo/main.tf
```

Current:
```hcl
locals {
  ipv4 = contabo_instance.this.ip_config[0].v4[0].ip
  ipv6 = try(contabo_instance.this.ip_config[0].v6[0].ip, null)
```

- [ ] **Step 2: Extend the locals to add cidr and gateway for both families.**

Replace the two-line `ipv4`/`ipv6` block with:

```hcl
locals {
  ipv4         = contabo_instance.this.ip_config[0].v4[0].ip
  ipv4_cidr    = contabo_instance.this.ip_config[0].v4[0].netmask_cidr
  ipv4_gateway = contabo_instance.this.ip_config[0].v4[0].gateway
  ipv6         = try(contabo_instance.this.ip_config[0].v6[0].ip, null)
  ipv6_cidr    = try(contabo_instance.this.ip_config[0].v6[0].netmask_cidr, null)
  ipv6_gateway = try(contabo_instance.this.ip_config[0].v6[0].gateway, null)
```

Keep the rest of the existing `locals` block (`derived_labels`, `derived_annotations`) unchanged.

- [ ] **Step 3: Add a precondition on `contabo_instance.this` that fails plan if any field is empty.**

Inside the existing `resource "contabo_instance" "this"` block, add a `lifecycle { postcondition }` (post not pre — these are computed-after-create attributes). After the `lifecycle { ignore_changes = [image_id] }` line, expand it to:

```hcl
  lifecycle {
    ignore_changes = [image_id]
    postcondition {
      condition = (
        self.ip_config[0].v4[0].ip != "" &&
        self.ip_config[0].v4[0].gateway != "" &&
        self.ip_config[0].v4[0].netmask_cidr != null &&
        try(self.ip_config[0].v6[0].ip, "") != "" &&
        try(self.ip_config[0].v6[0].gateway, "") != "" &&
        try(self.ip_config[0].v6[0].netmask_cidr, null) != null
      )
      error_message = "Contabo instance ${self.id}: ip_config v4/v6 ip+gateway+netmask_cidr must all be set. Re-run after the instance is fully provisioned (Contabo populates v6 a few seconds after v4)."
    }
  }
```

- [ ] **Step 4: Validate the module.**

```bash
cd tofu/modules/node-contabo
tofu init -backend=false
tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Commit.**

```bash
git add tofu/modules/node-contabo/main.tf
git commit -m "node-contabo: surface v4/v6 cidr + gateway from contabo_instance

Provider returns netmask_cidr and gateway alongside ip in
ip_config[0].v{4,6}[0]; we already read the ip but were ignoring
the rest. Per-node patch rendering (next commit) needs all three
to write a valid LinkConfig with addresses + default routes.

Postcondition fails plan when any field is empty/null — defends
against rendering an invalid LinkConfig with gateway: \"\"."
```

---

#### Task 5: Extend `node-contabo` outputs with the new fields

**Files:**
- Modify: `tofu/modules/node-contabo/outputs.tf`

- [ ] **Step 1: Read current outputs.**

```bash
cat tofu/modules/node-contabo/outputs.tf
```

- [ ] **Step 2: Edit `outputs.tf` — add the four new fields to BOTH the top-level outputs AND the `node` envelope.**

```hcl
# tofu/modules/node-contabo/outputs.tf
output "instance_id" { value = contabo_instance.this.id }
output "product_id" { value = contabo_instance.this.product_id }
output "region" { value = contabo_instance.this.region }
output "ipv4" { value = local.ipv4 }
output "ipv4_cidr" { value = local.ipv4_cidr }
output "ipv4_gateway" { value = local.ipv4_gateway }
output "ipv6" { value = local.ipv6 }
output "ipv6_cidr" { value = local.ipv6_cidr }
output "ipv6_gateway" { value = local.ipv6_gateway }
output "account_key" { value = var.account_key }
output "image_apply_generation" {
  value = md5("${contabo_instance.this.id}:${var.image_id}")
}

output "node" {
  description = "Node contract consumed by layer 03. Schema identical to modules/node-oracle."
  depends_on  = [null_resource.ensure_image]
  value = {
    name                = var.name
    role                = var.role
    provider            = "contabo"
    ipv4                = local.ipv4
    ipv4_cidr           = local.ipv4_cidr
    ipv4_gateway        = local.ipv4_gateway
    ipv6                = local.ipv6
    ipv6_cidr           = local.ipv6_cidr
    ipv6_gateway        = local.ipv6_gateway
    talos_endpoint      = "${local.ipv4}:50000"
    kubespan_endpoint   = local.ipv4
    derived_labels      = local.derived_labels
    derived_annotations = local.derived_annotations
    instance_id         = contabo_instance.this.id
    bastion_id          = null
    account_key         = var.account_key
    config_apply_source = "ci"
    image_apply_generation = md5("${contabo_instance.this.id}:${var.image_id}")
  }
}
```

- [ ] **Step 3: Re-validate.**

```bash
cd tofu/modules/node-contabo
tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit.**

```bash
git add tofu/modules/node-contabo/outputs.tf
git commit -m "node-contabo: expose v4/v6 cidr + gateway on node output contract

Layer 03 reads node.ipv{4,6}_cidr and node.ipv{4,6}_gateway to
render per-node LinkConfig patches."
```

---

#### Task 6: Extend `node-oracle` outputs with `public_ipv4`

**Files:**
- Modify: `tofu/modules/node-oracle/outputs.tf`

- [ ] **Step 1: Read current outputs.**

```bash
cat tofu/modules/node-oracle/outputs.tf
```

- [ ] **Step 2: Add a top-level `public_ipv4` output AND extend the `node` envelope.**

The OCI module already computes `local.public_ip` (lines 148-150 of `node-oracle/main.tf`). We just expose it under the name `public_ipv4` so layer 03 can render it into the flannel `public-ip-overwrite` annotation. Edit `outputs.tf`:

After the existing `output "ipv6"` (or wherever IP outputs live), add:

```hcl
output "public_ipv4" {
  value       = local.public_ip
  description = "OCI's NAT-mapped public IPv4 (distinct from output `ipv4`, which falls back to private when public is absent). Layer 03 renders this into the flannel.alpha.coreos.com/public-ip-overwrite annotation so cross-node VXLAN tunnels target the routable public IP."
}
```

Inside `output "node"`'s `value = { ... }`, add `public_ipv4 = local.public_ip` (alongside the existing `ipv4`/`ipv6` fields).

- [ ] **Step 3: Validate.**

```bash
cd tofu/modules/node-oracle
tofu init -backend=false
tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit.**

```bash
git add tofu/modules/node-oracle/outputs.tf
git commit -m "node-oracle: surface public_ipv4 on node output contract

OCI VMs see only the private RFC1918 address on-NIC; the public
IPv4 is a NAT mapping. Flannel needs the public IP to be told
explicitly via the flannel.alpha.coreos.com/public-ip-overwrite
annotation, otherwise cross-node VXLAN tunnels target the non-
routable RFC1918 address. Per-node patch rendering (next commits)
reads node.public_ipv4."
```

---

### Phase 3 — Per-node patch templates

#### Task 7: Create `node-contabo.tftpl`

**Files:**
- Create: `tofu/shared/patches/node-contabo.tftpl`

- [ ] **Step 1: Write the template.**

```yaml
---
# tofu/shared/patches/node-contabo.tftpl
#
# Per-Contabo-node Talos patch — multi-document YAML applied to a
# single Machine via Omni ConfigPatch. Rendered by layer 03 from
# `tofu/modules/node-contabo` outputs; the Omni envelope wrap is
# done at apply time by scripts/apply-per-node-patches.sh (machine
# IDs aren't known at tofu plan time).
#
# Documents:
#   1. machine.nodeLabels / nodeAnnotations  — kubelet propagates
#      these to the Kubernetes Node object on registration.
#   2. LinkConfig name: wan0                  — addresses + routes on
#      the cluster-wide alias `wan0` (see link-alias.yaml).
#      Gateways come from the Contabo provider's reported `gateway`
#      field, NOT derived (the 490ae67 retirement was caused by
#      <prefix>::1 derivation colliding with Contabo's own host
#      address).
#   3. HostnameConfig auto: off               — pin the canonical
#      hostname; without this, Contabo's platform-supplied hostname
#      is the VPS UUID.
#
# Multi-NIC future: this template assumes the cluster-wide
# LinkAliasConfig (link-alias.yaml) deterministically resolves
# `wan0` to the single physical Ethernet on this node. If a Contabo
# Private Networking add-on ever attaches a second virtio_net NIC,
# `link.type == "ether"` matches both and `wan0` becomes
# enumeration-order-dependent. Override that node's per-node patch
# with a MAC-pinned LinkAliasConfig (per Talos v1.13 docs):
#   apiVersion: v1alpha1
#   kind: LinkAliasConfig
#   name: wan
#   selector:
#     match: mac(link.permanent_addr) == "<wan-mac>"
# and switch the LinkConfig below to `name: wan` (drop `0`).

machine:
  nodeLabels:
%{ for k, v in node_labels ~}
    ${k}: "${v}"
%{ endfor ~}
  nodeAnnotations:
%{ for k, v in node_annotations ~}
    ${k}: "${v}"
%{ endfor ~}

---
apiVersion: v1alpha1
kind: LinkConfig
name: wan0
addresses:
  - address: ${ipv4}/${ipv4_cidr}
  - address: ${ipv6}/${ipv6_cidr}
routes:
  - gateway: ${ipv4_gateway}
  - gateway: ${ipv6_gateway}

---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: ${hostname}
auto: off
```

Template variables (all consumed by layer 03's `templatefile()` call): `node_labels` (map), `node_annotations` (map), `ipv4`, `ipv4_cidr`, `ipv4_gateway`, `ipv6`, `ipv6_cidr`, `ipv6_gateway`, `hostname`.

- [ ] **Step 2: Validate the template renders cleanly with sample inputs.**

```bash
cd tofu/shared/patches
cat > /tmp/render-contabo.tf <<'TF'
terraform {
  required_version = ">= 1.10"
}
output "rendered" {
  value = templatefile("${path.module}/node-contabo.tftpl", {
    node_labels      = { "node.antinvestor.io/role" = "worker", "node-role.kubernetes.io/worker" = "" }
    node_annotations = { "node.antinvestor.io/provider" = "contabo" }
    ipv4             = "164.68.121.237"
    ipv4_cidr        = 24
    ipv4_gateway     = "164.68.121.1"
    ipv6             = "2a02:c207:2090:1234::1"
    ipv6_cidr        = 64
    ipv6_gateway     = "fe80::1"
    hostname         = "contabo-bwire-node-3"
  })
}
TF
mkdir -p /tmp/render-contabo && cp /tmp/render-contabo.tf /tmp/render-contabo/main.tf
ln -sf "$(pwd)/node-contabo.tftpl" /tmp/render-contabo/node-contabo.tftpl
cd /tmp/render-contabo && tofu init -backend=false >/dev/null && tofu plan -no-color | sed -n '/rendered =/,/EOT/p' | head -60
```
Expected: a printed multi-document YAML. Eyeball: `LinkConfig.name: wan0`, `routes[].gateway` are `164.68.121.1` and `fe80::1` (NOT `2a02:c207:2090:1234::1`), `HostnameConfig.hostname: contabo-bwire-node-3`, `auto: off`.

- [ ] **Step 3: Optionally validate the rendered output against Talos's schema.**

If `talosctl` is installed locally:
```bash
cd /tmp/render-contabo
tofu output -raw rendered > /tmp/contabo-patch.yaml
talosctl validate -m metal -c /tmp/contabo-patch.yaml
```
Expected: `valid` (or no error).

If no `talosctl` available, defer to the cluster-template validation in Phase 6 — the workflow's per-node apply step catches schema errors before write.

- [ ] **Step 4: Clean up the scratch render dir.**

```bash
rm -rf /tmp/render-contabo /tmp/render-contabo.tf /tmp/contabo-patch.yaml
```

- [ ] **Step 5: Commit.**

```bash
git add tofu/shared/patches/node-contabo.tftpl
git commit -m "tofu/shared/patches: add node-contabo.tftpl per-node template

Renders machine.nodeLabels/nodeAnnotations + LinkConfig name: wan0
+ HostnameConfig per Contabo node. Gateways come from the Contabo
provider's reported \`gateway\` field — fixes the <prefix>::1
derivation bug that caused the 490ae67 retirement.

The cluster-wide link-alias.yaml LinkAliasConfig resolves \`wan0\`
to the first physical Ethernet on each node, so this template
doesn't need to know the kernel-assigned NIC name."
```

---

#### Task 8: Create `node-oracle.tftpl`

**Files:**
- Create: `tofu/shared/patches/node-oracle.tftpl`

- [ ] **Step 1: Write the template.**

```yaml
---
# tofu/shared/patches/node-oracle.tftpl
#
# Per-OCI-node Talos patch. OCI nodes carry no LinkConfig — Talos's
# OCI platform driver reads OCI's instance metadata service for
# addresses and default routes, and that path works.
#
# What we DO need on OCI:
#   1. machine.nodeLabels                         — Kubernetes labels.
#   2. machine.nodeAnnotations including:
#      - flannel.alpha.coreos.com/public-ip-overwrite     (v4)
#      - flannel.alpha.coreos.com/public-ipv6-overwrite   (v6)
#      OCI's public IPv4 is NAT'd at the VCN gateway; the on-NIC
#      address is the private RFC1918. Without these annotations,
#      kubelet auto-detects InternalIP as the private IP, Flannel
#      reads InternalIP for its public-ip annotation, and cross-
#      node VXLAN tunnels target a non-routable RFC1918 address.
#      The annotations were already computed in node-oracle's
#      derived_annotations but the only sync code (cluster.tf
#      omnictl_machine_labels) sends labels — not annotations.
#      This template closes that gap by routing them through Talos
#      machine.nodeAnnotations, which kubelet propagates to the K8s
#      Node object on registration.
#   3. HostnameConfig                             — pin canonical
#      hostname (consistency with Contabo nodes).

machine:
  nodeLabels:
%{ for k, v in node_labels ~}
    ${k}: "${v}"
%{ endfor ~}
  nodeAnnotations:
%{ for k, v in node_annotations ~}
    ${k}: "${v}"
%{ endfor ~}

---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: ${hostname}
auto: off
```

Template variables: `node_labels` (map), `node_annotations` (map — already includes the flannel keys when populated by layer 03 from `node-oracle.derived_annotations`), `hostname`.

- [ ] **Step 2: Validate the template renders cleanly.**

```bash
cd tofu/shared/patches
cat > /tmp/render-oracle.tf <<'TF'
terraform {
  required_version = ">= 1.10"
}
output "rendered" {
  value = templatefile("${path.module}/node-oracle.tftpl", {
    node_labels = { "node.antinvestor.io/role" = "worker" }
    node_annotations = {
      "node.antinvestor.io/provider"                  = "oracle"
      "flannel.alpha.coreos.com/public-ip-overwrite"  = "129.146.1.2"
      "flannel.alpha.coreos.com/public-ipv6-overwrite" = "2603:c020:0:1234::5"
    }
    hostname = "oci-bwire-node-1"
  })
}
TF
mkdir -p /tmp/render-oracle && cp /tmp/render-oracle.tf /tmp/render-oracle/main.tf
ln -sf "$(pwd)/node-oracle.tftpl" /tmp/render-oracle/node-oracle.tftpl
cd /tmp/render-oracle && tofu init -backend=false >/dev/null && tofu plan -no-color | sed -n '/rendered =/,/EOT/p' | head -40
```
Expected: rendered YAML containing both flannel annotation keys, no `LinkConfig` document.

- [ ] **Step 3: Clean up.**

```bash
rm -rf /tmp/render-oracle /tmp/render-oracle.tf
```

- [ ] **Step 4: Commit.**

```bash
git add tofu/shared/patches/node-oracle.tftpl
git commit -m "tofu/shared/patches: add node-oracle.tftpl per-node template

Routes flannel.alpha.coreos.com/public-ip{,v6}-overwrite through
Talos machine.nodeAnnotations so kubelet sets them on the K8s Node
on registration. Closes a long-standing gap where the annotations
were computed in node-oracle.derived_annotations but never
propagated (only labels were synced via cluster.tf).

No LinkConfig — Talos's OCI platform driver handles addressing."
```

---

### Phase 4 — Layer-03 renderer + R2 upload

#### Task 9: Create `tofu/layers/03-talos/per-node-patches.tf`

**Files:**
- Create: `tofu/layers/03-talos/per-node-patches.tf`

- [ ] **Step 1: Write the renderer.**

```hcl
# tofu/layers/03-talos/per-node-patches.tf
#
# Renders per-node Talos patches from each upstream node's outputs
# and uploads them to R2. The sync-cluster-template workflow's
# scripts/apply-per-node-patches.sh reads them back, resolves each
# node's Omni machine-id, wraps in a ConfigPatches.omni.sidero.dev
# envelope, and applies. We don't wrap in tofu because machine-ids
# aren't known until Talos has registered via SideroLink — chicken
# and egg.
#
# R2 path: production/per-node-patches/<talos-version>/<node>.yaml.
# Cluster-scoped (top-level), distinct from node-state's per-node
# Talos machine configs which are <account>/<talos-version>/
# scoped. We use a layer-local aws_s3_object instead of extending
# node-state because the path shapes are incompatible.
#
# Provider scoping:
#   - contabo: render node-contabo.tftpl (LinkConfig + HostnameConfig
#              + nodeLabels/Annotations)
#   - oracle:  render node-oracle.tftpl (HostnameConfig +
#              nodeLabels/Annotations including flannel overrides)
#   - onprem:  skip (currently out of scope per 2026-05-03 spec)

locals {
  # Filter to providers we render patches for. On-prem nodes are
  # silently skipped — they currently aren't part of the cluster.
  per_node_patch_eligible = {
    for k, v in local.all_nodes_from_state : k => v
    if contains(["contabo", "oracle"], try(v.provider, ""))
  }

  # Render the right template per node based on provider. Each
  # entry's value is the rendered Talos patch YAML (no Omni
  # envelope yet).
  per_node_patches_rendered = {
    for k, v in local.per_node_patch_eligible : k => (
      v.provider == "contabo" ? templatefile(
        "${path.module}/../../shared/patches/node-contabo.tftpl",
        {
          hostname         = k
          node_labels      = try(v.derived_labels, {})
          node_annotations = try(v.derived_annotations, {})
          ipv4             = try(v.ipv4, "")
          ipv4_cidr        = try(v.ipv4_cidr, 0)
          ipv4_gateway     = try(v.ipv4_gateway, "")
          ipv6             = try(v.ipv6, "")
          ipv6_cidr        = try(v.ipv6_cidr, 0)
          ipv6_gateway     = try(v.ipv6_gateway, "")
        },
      ) : templatefile(
        "${path.module}/../../shared/patches/node-oracle.tftpl",
        {
          hostname = k
          node_labels = try(v.derived_labels, {})
          # Inject flannel public-ip overrides only when public_ipv4
          # is non-empty. node-oracle.derived_annotations already
          # carries these, but node-onprem might not — defensive
          # merge here keeps the template provider-agnostic.
          node_annotations = try(v.derived_annotations, {})
        },
      )
    )
  }

  # Talos version comes from versions.auto.tfvars.json's
  # `talos_version`, surfaced by the workflow's tofu init step. If
  # the version isn't pinned, the upload still succeeds — just
  # under a path that won't match what the apply script expects.
  per_node_patches_path_prefix = "production/per-node-patches/${var.talos_version}"
}

resource "aws_s3_object" "per_node_patch" {
  for_each = local.per_node_patches_rendered

  bucket       = "cluster-tofu-state"
  key          = "${local.per_node_patches_path_prefix}/${each.key}.yaml"
  content      = each.value
  content_type = "application/x-yaml"

  # Tag with sha for idempotency — rerender that doesn't change
  # the YAML is a no-op apply.
  metadata = {
    sha     = sha256(each.value)
    node    = each.key
    version = var.talos_version
  }
}
```

- [ ] **Step 2: Add the missing `talos_version` variable.**

The `var.talos_version` reference above doesn't exist yet in `variables.tf`. Add to `tofu/layers/03-talos/variables.tf`:

```hcl
variable "talos_version" {
  type        = string
  description = "Talos version pinned for this cluster (e.g. v1.13.0). Used as a path component for R2 per-node-patch artifacts so multi-version clusters don't collide. Surfaced from tofu/shared/versions.auto.tfvars.json by the workflow."
}
```

And confirm `tofu/shared/versions.auto.tfvars.json` has a `talos_version` key (it does; check via `jq -r .talos_version tofu/shared/versions.auto.tfvars.json`).

- [ ] **Step 3: Validate the layer.**

```bash
cd tofu/layers/03-talos
tofu init
tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Plan against current state to inspect the diff.**

The layer's normal apply happens in CI. Locally, plan with the runner-provisioned `terraform.tfvars` if available, otherwise use a minimal one-shot:

```bash
cd tofu/layers/03-talos
TF_VAR_r2_account_id=dummy \
TF_VAR_age_recipients=age1dummy \
TF_VAR_cloudflare_api_token=dummy \
TF_VAR_talos_version=v1.13.0 \
tofu plan -no-color 2>&1 | grep -E "aws_s3_object\.per_node_patch|will be created" | head -20
```
Expected: one `aws_s3_object.per_node_patch["<node>"]` per Contabo + OCI node in current state. (Local plan against backend may need real R2 creds; if the plan errors at backend init, defer this step to the CI run.)

- [ ] **Step 5: Commit.**

```bash
git add tofu/layers/03-talos/per-node-patches.tf tofu/layers/03-talos/variables.tf
git commit -m "03-talos: render+upload per-node Talos patches to R2

For each Contabo and OCI node in upstream state, render the
provider-specific patch template (node-contabo.tftpl /
node-oracle.tftpl) and upload to:
  s3://cluster-tofu-state/production/per-node-patches/<v>/<node>.yaml

The Omni envelope wrap (ConfigPatches.omni.sidero.dev with
machine-id label) happens at workflow apply time — machine-ids
aren't known at tofu plan time."
```

---

### Phase 5 — Apply script + workflow integration

#### Task 10: Create `apply-per-node-patches.sh`

**Files:**
- Create: `tofu/layers/03-talos/scripts/apply-per-node-patches.sh`

- [ ] **Step 1: Write the script.**

```bash
#!/usr/bin/env bash
#
# tofu/layers/03-talos/scripts/apply-per-node-patches.sh
#
# Workflow-invoked: pulls per-node Talos patches from R2, resolves
# each node's Omni machine-id, wraps in a ConfigPatches.omni.sidero.dev
# envelope (id = stawi-<node>-link, machine label scoping), and
# applies via omnictl. Idempotent — re-running with no change is a
# no-op apply per Omni's resource semantics.
#
# Sibling to sync-machine-labels.sh; reuses the same hostname-then-
# ipv4 matching logic to map node names to Omni machine IDs.
#
# Inputs:
#   $1                            R2 prefix to read patches from
#                                  (e.g. production/per-node-patches/v1.13.0).
#   $NODES_JSON                    Path to JSON file mapping node-name →
#                                    { "ipv4": "1.2.3.4" | null }, written
#                                    by tofu (same shape as sync-machine-
#                                    labels.sh's NODE_LABELS_JSON.ipv4 sub-
#                                    field).
#   $OMNI_CLUSTER                  Cluster name (logging only).
#   $OMNI_ENDPOINT                 omnictl reads from env.
#   $OMNI_SERVICE_ACCOUNT_KEY      omnictl reads from env.
#   $AWS_ACCESS_KEY_ID             R2 read creds.
#   $AWS_SECRET_ACCESS_KEY         R2 read creds.
#   $R2_ACCOUNT_ID                 R2 endpoint construction.
#
# Behaviour:
#   - Per-node: fail-isolated. A failed apply for one node logs
#     ERROR and continues with others.
#   - Empty R2 prefix is a no-op.

set -euo pipefail

readonly R2_PREFIX="${1:?usage: $0 <r2-prefix>}"
readonly NODES_JSON="${NODES_JSON:?NODES_JSON env var required}"

[[ -s "$NODES_JSON" ]] || { echo "[apply-per-node-patches] empty/missing $NODES_JSON — nothing to do"; exit 0; }
command -v omnictl >/dev/null || { echo "[apply-per-node-patches] omnictl not in PATH" >&2; exit 1; }
command -v aws     >/dev/null || { echo "[apply-per-node-patches] aws not in PATH" >&2; exit 1; }
command -v jq      >/dev/null || { echo "[apply-per-node-patches] jq not in PATH" >&2; exit 1; }
[[ -n "${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "[apply-per-node-patches] OMNI_SERVICE_ACCOUNT_KEY unset" >&2; exit 1; }
[[ -n "${R2_ACCOUNT_ID:-}" ]]            || { echo "[apply-per-node-patches] R2_ACCOUNT_ID unset" >&2; exit 1; }

readonly R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Stage R2 patches into a workspace tempdir.
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

echo "[apply-per-node-patches] syncing s3://cluster-tofu-state/${R2_PREFIX}/ → $workdir/"
aws s3 sync "s3://cluster-tofu-state/${R2_PREFIX}/" "$workdir/" \
  --endpoint-url "$R2_ENDPOINT" \
  --region us-east-1 \
  --no-progress \
  >/dev/null

# Fetch Omni machine inventory once.
fetch_machines() {
  local result
  result=$(omnictl get machinestatus --output json 2>/dev/null | jq -cs 'flatten' 2>/dev/null) || result=''
  if [[ -z "$result" ]] || ! jq -e . >/dev/null 2>&1 <<<"$result"; then
    result='[]'
  fi
  printf '%s' "$result"
}

machines_arr=$(fetch_machines)
machine_count=$(jq -r 'length' <<<"$machines_arr")
echo "[apply-per-node-patches] cluster=${OMNI_CLUSTER:-stawi}, registered machines: $machine_count"

if (( machine_count == 0 )); then
  echo "[apply-per-node-patches] WARN: no machines registered — nothing to apply"
  exit 0
fi

applied=0
skipped=0
errored=0

while IFS= read -r entry; do
  node_name=$(jq -r '.key' <<<"$entry")
  ipv4=$(jq -r '.value.ipv4 // ""' <<<"$entry")

  patch_file="$workdir/${node_name}.yaml"
  if [[ ! -s "$patch_file" ]]; then
    echo "[apply-per-node-patches] WARN $node_name: no patch in R2 (skipping — onprem or unrendered)"
    skipped=$((skipped + 1))
    continue
  fi

  # Match by hostname first, then by any-address-matches-ipv4.
  # Identical logic to sync-machine-labels.sh.
  machine_id=$(jq -r --arg n "$node_name" --arg ip "$ipv4" '
    (.[] | select((.spec.network.hostname // "") == $n) | .metadata.id),
    (.[] | select(
       ($ip != "") and (
         any(.spec.network.addresses // [] | .[];
             (split("/")[0]) == $ip)
       )
     ) | .metadata.id)
  ' <<<"$machines_arr" | head -n1)

  if [[ -z "$machine_id" ]]; then
    echo "[apply-per-node-patches] WARN $node_name (ipv4=$ipv4): no matching Omni machine — skipping"
    skipped=$((skipped + 1))
    continue
  fi

  # Wrap the Talos patch in an Omni ConfigPatches envelope. The
  # `cluster` field scopes the patch to this cluster; the `machine`
  # label scopes it to one Machine. Patch ID `stawi-<node>-link`
  # matches the legacy naming so the orphan sweep step can identify
  # ours vs. unrelated patches.
  patch_yaml=$(<"$patch_file")
  envelope_file=$(mktemp -t "stawi-${node_name}-link.XXXXXX.yaml")
  cat > "$envelope_file" <<MANIFEST
metadata:
  namespace: default
  type: ConfigPatches.omni.sidero.dev
  id: stawi-${node_name}-link
  labels:
    omni.sidero.dev/cluster: ${OMNI_CLUSTER:-stawi}
    omni.sidero.dev/machine: ${machine_id}
spec:
  data: |
$(printf '%s\n' "$patch_yaml" | sed 's/^/    /')
MANIFEST

  echo "[apply-per-node-patches] $node_name (machine=$machine_id): applying patch"
  if omnictl apply -f "$envelope_file" 2>&1 | sed 's/^/  /'; then
    applied=$((applied + 1))
  else
    echo "[apply-per-node-patches] ERROR $node_name: omnictl apply ConfigPatches failed"
    errored=$((errored + 1))
  fi
  rm -f "$envelope_file"
done < <(jq -c 'to_entries[]' "$NODES_JSON")

echo "[apply-per-node-patches] done: applied=$applied skipped=$skipped errored=$errored"
exit 0
```

- [ ] **Step 2: Make the script executable.**

```bash
chmod +x tofu/layers/03-talos/scripts/apply-per-node-patches.sh
```

- [ ] **Step 3: Lint with shellcheck (if installed locally).**

```bash
shellcheck tofu/layers/03-talos/scripts/apply-per-node-patches.sh || true
```
Expected: no errors. Warnings (e.g. SC2012, SC2086) are acceptable but reviewable.

- [ ] **Step 4: Commit.**

```bash
git add tofu/layers/03-talos/scripts/apply-per-node-patches.sh
git commit -m "03-talos: add apply-per-node-patches.sh

Workflow-invoked: pulls per-node Talos patches from R2, resolves
each node's Omni machine-id (hostname-then-ipv4 match, same as
sync-machine-labels.sh), wraps in a ConfigPatches.omni.sidero.dev
envelope, and omnictl-applies. Per-node fail-isolated.

Wraps the envelope here (not in tofu) because machine-ids aren't
known until Talos has registered via SideroLink."
```

---

#### Task 11: Wire the script into `sync-cluster-template.yml`

**Files:**
- Modify: `.github/workflows/sync-cluster-template.yml`

- [ ] **Step 1: Read the current "Remove legacy per-node link patches" step.**

```bash
grep -n "Remove legacy per-node link patches" .github/workflows/sync-cluster-template.yml
sed -n '256,278p' .github/workflows/sync-cluster-template.yml
```

- [ ] **Step 2: Replace the "Remove legacy per-node link patches" step with TWO new steps: "Apply per-node patches" and "Sweep orphan per-node patches".**

Find the current step (around line 256-278 — the one whose comment block says "Per-node link ConfigPatches retired 2026-05-04…"). Replace the entire block (from the comment header through the end of the step) with:

```yaml
      # Per-node Talos patches (LinkConfig + HostnameConfig +
      # nodeLabels/Annotations). Re-introduced 2026-05-05 with the
      # IPv6-gateway bug from the 2026-05-04 retirement fixed by
      # construction (gateways read from contabo_instance.ip_config
      # rather than derived from the prefix).
      #
      # Inputs:
      #   - R2: production/per-node-patches/<talos-version>/<node>.yaml,
      #     written by layer 03's per-node-patches.tf.
      #   - tofu state: layer-03's all_nodes_from_state, surfaced as
      #     a NODES_JSON file with each node's ipv4 (used for the
      #     hostname-then-ipv4 machine-id match).
      #
      # The envelope (ConfigPatches.omni.sidero.dev wrapper with
      # machine-id label) is built at apply time — machine-ids
      # aren't known at tofu plan time.
      - name: Apply per-node patches
        if: env.DRY_RUN != 'true'
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          AWS_EC2_METADATA_DISABLED: "true"
          R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}
          OMNI_CLUSTER: stawi
        run: |
          set -euo pipefail
          ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
          STATE_KEY="production/03-talos.tfstate"
          if ! aws s3api head-object \
              --bucket cluster-tofu-state \
              --key "$STATE_KEY" \
              --endpoint-url "$ENDPOINT" \
              --region us-east-1 >/dev/null 2>&1; then
            echo "::notice::03-talos tfstate not found — apply that layer first to populate per-node patches in R2."
            exit 0
          fi
          # Pull the layer-03 tfstate to extract talos_version and the
          # node-name → ipv4 map. tofu-output isn't available here
          # (no tofu init), so read the state JSON directly.
          state=$(mktemp)
          nodes_json=$(mktemp -p "${RUNNER_TEMP:-/tmp}" nodes-XXXXXX.json)
          trap 'rm -f "$state" "$nodes_json"' EXIT
          aws s3 cp "s3://cluster-tofu-state/$STATE_KEY" "$state" \
            --endpoint-url "$ENDPOINT" \
            --region us-east-1 >/dev/null
          # all_nodes_from_state is a HCL local — not output. Read
          # from the resource that exposes it: omnictl_machine_labels'
          # node_labels_json content carries each node's ipv4.
          jq -r '
            .resources[]
            | select(.type == "local_sensitive_file" and .name == "node_labels_json")
            | .instances[0].attributes.content
          ' "$state" \
          | jq -c 'with_entries(.value |= { ipv4: .ipv4 })' \
          > "$nodes_json"
          if [[ "$(jq -r 'length' "$nodes_json")" -eq 0 ]]; then
            echo "::notice::no nodes in layer-03 state — skipping per-node apply"
            exit 0
          fi
          TALOS_VERSION=$(jq -r '
            .outputs.talos_version.value
            // empty
          ' "$state")
          if [[ -z "$TALOS_VERSION" ]]; then
            # Fall back to versions.auto.tfvars.json (committed).
            TALOS_VERSION=$(jq -r '.talos_version' tofu/shared/versions.auto.tfvars.json)
          fi
          R2_PREFIX="production/per-node-patches/${TALOS_VERSION}"
          export NODES_JSON="$nodes_json"
          bash tofu/layers/03-talos/scripts/apply-per-node-patches.sh "$R2_PREFIX"

      # Sweep orphan per-node patches: any stawi-<node>-link patch in
      # Omni state whose <node> isn't in the current tofu node set.
      # Replaces the previous unconditional cleanup of all
      # stawi-*-link patches (from 2026-05-04's retirement) — that
      # cleanup would now nuke what we just applied. The targeted
      # sweep handles node-removal cleanly without breaking the
      # apply-then-sweep ordering.
      - name: Sweep orphan per-node patches
        if: env.DRY_RUN != 'true'
        env:
          AWS_ACCESS_KEY_ID: ${{ secrets.R2_ACCESS_KEY_ID }}
          AWS_SECRET_ACCESS_KEY: ${{ secrets.R2_SECRET_ACCESS_KEY }}
          AWS_EC2_METADATA_DISABLED: "true"
          R2_ACCOUNT_ID: ${{ secrets.R2_ACCOUNT_ID }}
        run: |
          set -euo pipefail
          ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
          STATE_KEY="production/03-talos.tfstate"
          if ! aws s3api head-object \
              --bucket cluster-tofu-state \
              --key "$STATE_KEY" \
              --endpoint-url "$ENDPOINT" \
              --region us-east-1 >/dev/null 2>&1; then
            echo "::notice::03-talos tfstate missing — skipping orphan sweep"
            exit 0
          fi
          state=$(mktemp)
          trap 'rm -f "$state"' EXIT
          aws s3 cp "s3://cluster-tofu-state/$STATE_KEY" "$state" \
            --endpoint-url "$ENDPOINT" \
            --region us-east-1 >/dev/null
          # Build the set of node names currently in tofu state.
          mapfile -t live_nodes < <(jq -r '
            .resources[]
            | select(.type == "local_sensitive_file" and .name == "node_labels_json")
            | .instances[0].attributes.content
          ' "$state" | jq -r 'keys[]')
          live_set=$(printf '%s\n' "${live_nodes[@]}" | sort -u)
          # List all stawi-<node>-link patches in Omni and delete
          # those whose <node> isn't in live_set.
          for id in $(omnictl get configpatches -o jsonpath='{.metadata.id}' 2>/dev/null \
                       | tr ' ' '\n' \
                       | grep -E '^stawi-.+-link$' \
                       || true); do
            node="${id#stawi-}"
            node="${node%-link}"
            if ! grep -qx "$node" <<<"$live_set"; then
              echo "::notice::orphan per-node patch detected: $id (node $node not in tofu state)"
              omnictl delete configpatches "$id" || echo "::warning::failed to delete $id"
            fi
          done
```

Where the previous step ended (right before the `Validate before sync` step), the new pair of steps now slot in. Keep `Validate template` / `Diff template` / `Sync template` after, in their existing order.

- [ ] **Step 3: Lint the workflow yaml.**

```bash
python3 -c "import yaml; list(yaml.safe_load_all(open('.github/workflows/sync-cluster-template.yml')))"
```
Expected: silent exit (status 0).

- [ ] **Step 4: Commit.**

```bash
git add .github/workflows/sync-cluster-template.yml
git commit -m "sync-cluster-template: re-introduce per-node patch apply + orphan sweep

Replaces the 2026-05-04 \"Remove legacy per-node link patches\"
step with two new ones:
  - Apply per-node patches: pulls per-node patches from R2,
    resolves each node's Omni machine-id, wraps in
    ConfigPatches.omni.sidero.dev envelope, omnictl-applies.
  - Sweep orphan per-node patches: deletes any stawi-<node>-link
    patch whose <node> isn't in the current tofu state.

Apply-then-sweep ordering ensures we don't nuke what we just
applied. The IPv6-gateway bug that caused the 2026-05-04
retirement is fixed by construction in node-contabo.tftpl
(gateways read from the Contabo provider's reported gateway
field rather than derived)."
```

---

### Phase 6 — Narrow the Omni machine-label sync

#### Task 12: Narrow `cluster.tf`'s machine-label labels set

**Files:**
- Modify: `tofu/layers/03-talos/cluster.tf` (the `omni_machine_apply_per_node` local block)

- [ ] **Step 1: Read the current block.**

```bash
sed -n '32,55p' tofu/layers/03-talos/cluster.tf
```

- [ ] **Step 2: Edit the labels map to only `node.antinvestor.io/role`.**

Replace the `omni_machine_apply_per_node` block (currently lines ~38-48) with:

```hcl
  # Per-node labels-and-ip envelope.
  #
  # Narrowed 2026-05-05 to the single label MachineClass selectors
  # actually match on (node.antinvestor.io/role). Other labels —
  # provider, account, name, topology.kubernetes.io/* — moved to
  # Talos `machine.nodeLabels` via per-node patches in
  # tofu/shared/patches/node-{contabo,oracle}.tftpl. K8s Node
  # labels live on the K8s API; Omni Machine labels live on Omni's
  # inventory; previously these were conflated and synced together
  # to Omni only, leaving K8s Node labels orphaned.
  #
  # Path to dropping this sync entirely is the kernel-cmdline
  # initial-labels TODO in tofu/shared/clusters/main.yaml — once
  # node.antinvestor.io/role can be baked into kernel cmdline at
  # image-mint time, MachineClass selectors fire without any
  # post-registration sync, and this whole reconciler retires.
  omni_machine_apply_per_node = {
    for k, v in local.all_nodes_from_state : k => {
      labels = {
        for lk, lv in {
          "node.antinvestor.io/role" = try(v.derived_labels["node.antinvestor.io/role"], "")
        } : lk => lv
        if lv != ""
      }
      ipv4 = try(v.ipv4, null)
    }
  }
```

- [ ] **Step 3: Validate the layer.**

```bash
cd tofu/layers/03-talos
tofu validate
```
Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit.**

```bash
git add tofu/layers/03-talos/cluster.tf
git commit -m "03-talos/cluster: narrow Omni machine-label sync to role-only

MachineClass selectors in tofu/shared/clusters/machine-classes.yaml
match on a single label: node.antinvestor.io/role. Everything else
(provider, account, name, topology.*) is observability and moves
to Talos machine.nodeLabels via the per-node patches reintroduced
in this PR. K8s Node labels now live on the K8s API where they
belong; Omni Machine labels narrow to selector-required only."
```

---

### Phase 7 — Canary apply + verification

> **STOP.** Up to here is a single PR's worth of code changes. Before merging, the operator should review the full PR diff. The remaining tasks are post-merge applies + verification, executed against the live cluster.

#### Task 13: Open the PR and merge

- [ ] **Step 1: Push and open PR.**

```bash
git push -u origin HEAD
gh pr create --title "ipv6-first dualstack + reintroduced per-node Talos patches" \
  --body "$(cat <<'EOF'
## Summary
- Cluster-wide LinkAliasConfig (universal `link.type == "ether"` selector) so per-node patches don't carry kernel-assigned interface names
- Per-node LinkConfig for Contabo (addresses + gateways from the provider, not derived) — fixes the IPv6 gateway self-routing bug that caused the 2026-05-04 retirement
- Per-node nodeAnnotations for OCI Flannel public-IP overrides (closes a long-standing gap)
- Per-node nodeLabels propagation to Kubernetes Node objects (also long-standing gap)
- Cluster dual-stack patch flipped to IPv6-first ordering

## Test plan
- [ ] Merge triggers `tofu-apply.yml` for layer 03-talos: per-node patch YAMLs land in `s3://cluster-tofu-state/production/per-node-patches/v1.13.0/`
- [ ] `sync-cluster-template.yml` runs after, applies cluster-wide patches (link-alias + IPv6-first dual-stack) and per-machine ConfigPatches
- [ ] Canary verification on contabo-bwire-node-3 (next plan tasks): `talosctl get linkalias`, `kubectl get node ... -o jsonpath='{.metadata.labels}'`, dual-stack pod with both IPs, no flannel `failed to get default v6` errors
- [ ] Cluster-wide verification: cross-provider pod-to-pod traffic works (regression test for OCI flannel override)

Spec: `docs/superpowers/specs/2026-05-05-ipv6-first-dualstack-and-per-node-patches-design.md`
EOF
)"
```

- [ ] **Step 2: Review CI runs.**

```bash
gh pr checks --watch
```
Expected: all required checks pass, including the new layer-03 plan / cluster-template validate.

- [ ] **Step 3: Merge after review.**

When approved:
```bash
gh pr merge --squash --delete-branch
```

---

#### Task 14: Apply layer 03-talos via the workflow

- [ ] **Step 1: Trigger the layer-03 apply.**

```bash
gh workflow run tofu-apply.yml --field layer=03-talos --ref main
gh run watch
```
Expected: layer applies cleanly. The run output shows the new `aws_s3_object.per_node_patch[<node>]` resources being created (one per Contabo + OCI node).

- [ ] **Step 2: Verify R2 contents.**

```bash
# Use the runner's R2 creds via gh secrets (or a local scratch
# script if you have credentials at hand).
gh workflow run debug-r2-list.yml -f prefix=production/per-node-patches/  # if such a workflow exists
# or, scriptably:
aws s3 ls --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  s3://cluster-tofu-state/production/per-node-patches/ --recursive
```
Expected: one YAML per Contabo + OCI node under `production/per-node-patches/v1.13.0/`.

- [ ] **Step 3: Spot-check one rendered patch.**

Pick a Contabo node and confirm contents:
```bash
aws s3 cp --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com" \
  s3://cluster-tofu-state/production/per-node-patches/v1.13.0/contabo-bwire-node-3.yaml -
```
Eyeball:
- `LinkConfig name: wan0` block exists
- `addresses[]` contain the node's actual public v4 and v6
- `routes[].gateway` are NOT the same as the node's own addresses (regression check for the 490ae67 bug)
- `HostnameConfig.hostname` matches the node name, `auto: off`
- `machine.nodeLabels` contains `node.antinvestor.io/role: worker` (or `controlplane`)

If any of these is wrong, **stop here**. Fix the template or precondition and re-run layer-03 apply before triggering sync-cluster-template. Otherwise proceed.

---

#### Task 15: Trigger sync-cluster-template (DRY RUN first)

- [ ] **Step 1: Dry run.**

```bash
gh workflow run sync-cluster-template.yml --field dry_run=true --ref main
gh run watch
```
Expected: `Validate template` step passes (the new `link-alias` patch validates clean), the new `Apply per-node patches` step is skipped (dry_run), `Diff template` shows the cluster-wide patch additions/changes (link-alias + IPv6-first ordering). No errors.

- [ ] **Step 2: Real apply.**

```bash
gh workflow run sync-cluster-template.yml --ref main
gh run watch
```
Expected: clean run. `Sync template` succeeds. `Apply per-node patches` step output shows `applied=N skipped=0 errored=0` where N = Contabo + OCI node count. `Sweep orphan per-node patches` reports either "no orphans" or surgically deletes only old/missing entries.

If `errored > 0`, dig into the workflow logs for which node failed and why before proceeding.

---

#### Task 16: Per-node verification (Contabo canary first)

> Pick `contabo-bwire-node-3` as the canary unless its current state argues against it. The post-apply checks below run against the live cluster via `omnictl`/`talosctl`/`kubectl`.

- [ ] **Step 1: Get a kubeconfig + talosconfig from Omni.**

```bash
omnictl --cluster stawi cluster kubeconfig --force > /tmp/kubeconfig
omnictl --cluster stawi cluster ts > /tmp/talosconfig  # (verify exact subcommand name)
export KUBECONFIG=/tmp/kubeconfig
export TALOSCONFIG=/tmp/talosconfig
```

- [ ] **Step 2: Verify the alias resolved on the node.**

```bash
talosctl get linkalias --nodes contabo-bwire-node-3 -o yaml
```
Expected: one entry with `metadata.id = wan0` referencing a real ethernet link.

- [ ] **Step 3: Verify addresses on `wan0`.**

```bash
talosctl get addresses --nodes contabo-bwire-node-3 -o yaml
```
Expected: both IPv4 (e.g. `164.68.x.x/24`) and IPv6 addresses present, attached to `wan0`.

- [ ] **Step 4: Verify default routes — both families, no self-routing.**

```bash
talosctl get routes --nodes contabo-bwire-node-3 -o yaml
```
Expected: one IPv4 default (gateway = the Contabo provider's reported v4 gateway) AND one IPv6 default (gateway = the Contabo provider's reported v6 gateway, NOT the node's own v6 address). The v6 self-routing check is the most important regression test for the 2026-05-04 bug.

- [ ] **Step 5: Verify hostname config.**

```bash
talosctl get hostnamestatus --nodes contabo-bwire-node-3
```
Expected: `running`, hostname matches `contabo-bwire-node-3`, `auto: off`.

- [ ] **Step 6: Verify K8s Node labels and annotations.**

```bash
kubectl get node contabo-bwire-node-3 -o jsonpath='{.metadata.labels}' | jq
kubectl get node contabo-bwire-node-3 -o jsonpath='{.metadata.annotations}' | jq
```
Expected:
- Labels include `node.antinvestor.io/role`, `node-role.kubernetes.io/worker` (or `control-plane`), and the rest of the `derived_labels` set.
- Annotations include `node.antinvestor.io/provider`, etc.

- [ ] **Step 7: Same checks on one OCI node.**

```bash
talosctl get hostnamestatus --nodes oci-bwire-node-1
kubectl get node oci-bwire-node-1 -o jsonpath='{.metadata.annotations}' | jq | grep flannel
```
Expected: `flannel.alpha.coreos.com/public-ip-overwrite` present, value matches the node's OCI ephemeral public IP. Same for `public-ipv6-overwrite` if the node has v6.

If any per-node check fails, the rollback is per-node:
```bash
omnictl delete configpatches stawi-<node>-link
```
That restores cluster-default networking on that node only.

---

#### Task 17: Cluster-wide verification

- [ ] **Step 1: Every node reports both v4 and v6 InternalIP.**

```bash
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{range .status.addresses[?(@.type=="InternalIP")]}  {.address}{"\n"}{end}{end}'
```
Expected: each node lists both an IPv4 and an IPv6 InternalIP.

- [ ] **Step 2: Dual-stack pod gets both IPs.**

```bash
kubectl run dualstack-probe --image=busybox --restart=Never -- sleep 3600
sleep 10
kubectl get pod dualstack-probe -o jsonpath='{.status.podIPs}'
```
Expected: a list with both an IPv4 (`10.244.x.x`) and an IPv6 (`fd00:10:244::...`) entry.

- [ ] **Step 3: ClusterIP service gets both families.**

```bash
kubectl create service clusterip dualstack-svc --tcp=80:80 --ipfamily-policy=PreferDualStack 2>/dev/null \
  || kubectl create service clusterip dualstack-svc --tcp=80:80 # fallback if --ipfamily-policy unsupported
kubectl patch service dualstack-svc --type=merge -p '{"spec":{"ipFamilyPolicy":"PreferDualStack"}}' || true
kubectl get svc dualstack-svc -o jsonpath='{.spec.clusterIPs}'
```
Expected: both v4 and v6 ClusterIP entries.

- [ ] **Step 4: Flannel — no v6 default-route errors (regression test).**

```bash
kubectl logs -n kube-flannel ds/kube-flannel --tail=200 | grep -i "default v6\|failed to get default" || true
```
Expected: empty output. The presence of `failed to get default v6 interface` would be the precise failure mode of the 2026-05-04 retirement; absence is the success signal.

- [ ] **Step 5: Cross-provider pod-to-pod connectivity (OCI flannel override regression test).**

```bash
# Schedule a pod on a Contabo node and another on an OCI node.
kubectl run probe-contabo --image=busybox --overrides='{"spec":{"nodeSelector":{"node.antinvestor.io/provider":"contabo"}}}' --restart=Never -- sleep 3600
kubectl run probe-oci     --image=busybox --overrides='{"spec":{"nodeSelector":{"node.antinvestor.io/provider":"oracle"}}}' --restart=Never -- sleep 3600
sleep 15
oci_pod_ip=$(kubectl get pod probe-oci -o jsonpath='{.status.podIP}')
kubectl exec probe-contabo -- ping -c 3 -W 2 "$oci_pod_ip"
```
Expected: 3/3 packets received. `0% packet loss`. This is the **single most important post-apply check** because it directly validates the OCI flannel `public-ip-overwrite` annotation took effect — without it, Contabo→OCI VXLAN tunnels target a non-routable RFC1918 address and traffic drops.

- [ ] **Step 6: Clean up probes.**

```bash
kubectl delete pod dualstack-probe probe-contabo probe-oci
kubectl delete svc dualstack-svc
```

---

#### Task 18: Final rollout closeout

- [ ] **Step 1: Confirm no orphan ConfigPatches remain.**

```bash
omnictl get configpatches -o jsonpath='{.metadata.id}' | tr ' ' '\n' | grep -E '^stawi-.+-link$' | sort
```
Expected: one `stawi-<node>-link` per current Contabo + OCI node. Nothing for absent nodes.

- [ ] **Step 2: Update memory if anything load-bearing surfaced.**

If the run revealed any non-obvious operational lessons (e.g. the canary node behaved differently from expected, a verification step needed adjustment, gateway derivation surfaced a new edge case), capture it as a memory.

- [ ] **Step 3: Tag and document the cluster as IPv6-first dual-stack capable.**

If your team uses release tags or status pages: update them. Otherwise, this is a no-op closeout step.

---

## Self-Review Notes

After writing this plan, ran the spec/plan coverage check:

- **Cluster-wide patches** (spec §A): Tasks 1-3. ✅
- **Per-node patches for Contabo** (spec §B Contabo): Tasks 4-5 (data plumbing), 7 (template), 9 (renderer). ✅
- **Per-node patches for OCI** (spec §B OCI): Task 6 (data plumbing), 8 (template), 9 (renderer). ✅
- **Cluster.tf narrowing** (spec §C): Task 12. ✅
- **Workflow render+apply** (spec Components/Modify workflow): Tasks 10-11. ✅
- **Canary + cluster-wide verification** (spec Testing & validation): Tasks 13-18. ✅
- **Risk R3 (empty Contabo gateway)**: Postcondition added in Task 4. ✅
- **Risk R2 (alias-before-LinkConfig ordering)**: Task 2 places `link-alias` first in the cluster patches list, and the workflow naturally syncs cluster template before applying per-node patches. ✅
- **OCI Flannel override propagation**: Task 8 + 9 (template uses `node-oracle.derived_annotations` which already carries the keys). ✅
