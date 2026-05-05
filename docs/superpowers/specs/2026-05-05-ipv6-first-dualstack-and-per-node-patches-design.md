# IPv6-first dual-stack + reintroduced per-node Talos patches — design

> **Status:** Draft
> **Date:** 2026-05-05
> **Scope:** Single PR. Restores per-node Talos networking patches retired in `490ae67`/`7c7b6cd`, with the IPv6-gateway bug fixed by construction; folds OCI Flannel public-IP overrides and Kubernetes Node label/annotation propagation into the same flow; flips cluster-wide subnets to IPv6-first ordering. Targets all current cluster nodes (Contabo + OCI). On-prem `tindase` is out of scope per the 2026-05-03 realignment.

## Goal

Restore IPv6-first dual-stack as a working cluster-wide property, by:

1. Reintroducing per-node `LinkConfig` for Contabo nodes (static IPv4 + IPv6 + default routes) — read from the Contabo provider's reported `gateway` field rather than derived, eliminating the `<prefix>::1` self-routing bug that caused the 2026-05-04 retirement.
2. Selecting the primary uplink via Talos v1.13's `LinkAliasConfig` (`name: wan%d, selector: link.type == "ether"`) — provider-agnostic, no kernel-name discovery, no per-provider branching.
3. Wiring OCI's Flannel public-IP overrides through Talos `machine.nodeAnnotations` so cross-node VXLAN works on OCI's NAT'd public IPv4. (Currently parked in `derived_annotations` but never propagated to Kubernetes Node objects.)
4. Folding all Kubernetes Node labels/annotations into the per-node patch (`machine.nodeLabels`, `machine.nodeAnnotations`), narrowing `cluster.tf`'s Omni machine-label sync to only `node.antinvestor.io/role` — the one label MachineClass selectors actually match on.
5. Flipping the cluster-template `dual-stack` patch's `podSubnets`/`serviceSubnets` ordering so IPv6 entries are listed first.
6. Adding per-node `HostnameConfig` (`auto: off`) so Contabo doesn't use its VPS UUID as the hostname.

## Why

- **IPv6 on Contabo is currently broken.** The 2026-05-04 retirement walked back to "trust Talos defaults + RA-based v6", which doesn't work on Contabo (RAs aren't reliably accepted with `forwarding=1` even with `accept_ra=2`). Nodes silently stay v4-only; dual-stack is dual-stack in name only.
- **OCI cross-node Flannel-VXLAN has been broken for an unknown duration.** OCI's public IPv4 is NAT'd at the VCN gateway — the on-NIC address is RFC1918. Without a `flannel.alpha.coreos.com/public-ip-overwrite` annotation on the K8s Node, peer nodes try to tunnel to a non-routable RFC1918 address. The annotation is computed in `node-oracle/main.tf:186-194` but the only sync code today (`cluster.tf`) syncs *labels*, not annotations.
- **Kubernetes Node labels (e.g. `node-role.kubernetes.io/worker`) are missing from `kubectl get nodes`.** They're documented intent in `derived_labels` but the propagation path (Talos `machine.nodeLabels` via per-node patch) was retired with the link patches.
- **Resolving all three in one PR is cheaper than three** because the carrier — per-machine `ConfigPatches.omni.sidero.dev` rendered in layer 03 and applied by the workflow — is shared infrastructure.

## Background

### What 2026-05-04 retired

`490ae67` deleted `tofu/shared/patches/node-contabo.tftpl` and `tofu/shared/clusters/per-node-patches.yaml.tmpl`. `7c7b6cd` removed the corresponding render+apply workflow step and replaced it with a legacy-cleanup step that deletes any `stawi-<node>-link` `ConfigPatches` still in Omni state.

The retirement reason was specific: the IPv6 gateway derivation used `<ipv6_prefix>::1`, but Contabo assigns each VPS its primary IPv6 address as `<prefix>::1` too — Talos got a self-routing v6 gateway, networking broke, CP wedged in CONFIGURING. The `LinkAliasConfig`-based primary-uplink selection was paradigmatically correct; the gateway derivation was the bug.

### Talos v1.13 LinkAliasConfig — verified facts

From `siderolabs/talos/v1.13` docs:
- `LinkAliasConfig` aliases physical links only — logical links (wireguard, bonds, vlans, sidero) are excluded automatically. We don't need a `physical: true` filter; it's implicit.
- Selectors are CEL expressions over the LinkStatus resource (`link.type`, `link.kind`, `link.driver`, `link.permanent_addr`, `link.hardwareAddr`, etc.) with helpers `mac()` and `glob()`.
- A fixed alias name (`wan`) requires the selector to match exactly one link. A format-verb name (`wan%d`) accepts multiple matches and assigns sequential aliases.

### Contabo provider — verified facts

`contabo/terraform-provider-contabo` exposes `ip_config[0].v4[0]` and `ip_config[0].v6[0]` with fields `ip`, `netmask_cidr`, `gateway`. The `gateway` field is the authoritative value returned by Contabo's API on instance creation — no derivation needed.

## Architecture

### Three layers of Talos config

**A. Cluster-wide patches** — applied to every machine in the cluster via Omni cluster template `patches:` block:

1. **`link-alias`** (NEW)
   ```yaml
   apiVersion: v1alpha1
   kind: LinkAliasConfig
   name: wan%d
   selector:
     match: link.type == "ether"
   ```
   Aliases the first physical Ethernet on every node to `wan0`. Universal — Contabo virtio_net, OCI virtio_net, on-prem (any driver) all match.

2. **`dual-stack`** (existing, modified) — flip subnet ordering to IPv6-first:
   ```yaml
   cluster:
     network:
       podSubnets:
         - fd00:10:244::/56     # IPv6 first
         - 10.244.0.0/16
       serviceSubnets:
         - fd00:10:96::/108     # IPv6 first
         - 10.96.0.0/12
   machine:
     kubelet:
       nodeIP:
         validSubnets:
           - 0.0.0.0/0
           - ::/0
           - "!fdae:41e4:649b:9303::/64"   # exclude SideroLink ULA
   ```

3. **`contabo-ipv6-ra`** (existing, kept) — sysctl `accept_ra=2`. Defensive; harmless on OCI.

4. **`resolvers.yaml`** (existing at `tofu/shared/patches/resolvers.yaml`, no change) — IPv6-first nameservers.

**B. Per-node patches** — rendered from tofu state, applied as Omni per-machine `ConfigPatches.omni.sidero.dev`:

*Contabo:*
```yaml
machine:
  nodeLabels:
    # all keys from node-contabo.derived_labels
  nodeAnnotations:
    # all keys from node-contabo.derived_annotations
---
apiVersion: v1alpha1
kind: LinkConfig
name: wan0
addresses:
  - address: ${IPV4}/${IPV4_CIDR}
  - address: ${IPV6}/${IPV6_CIDR}
routes:
  - gateway: ${IPV4_GATEWAY}
  - gateway: ${IPV6_GATEWAY}
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: ${HOSTNAME}
auto: off
```

*OCI:*
```yaml
machine:
  nodeLabels:
    # all keys from node-oracle.derived_labels
  nodeAnnotations:
    # all keys from node-oracle.derived_annotations,
    # which already includes flannel.alpha.coreos.com/public-ip-overwrite
    # and public-ipv6-overwrite per node-oracle/main.tf
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: ${HOSTNAME}
auto: off
```

OCI nodes carry no `LinkConfig` — Talos's OCI platform driver reads OCI's instance metadata service for addresses and default routes, and the cluster has been operating without per-node OCI link config successfully.

**C. Per-machine sync narrowing**

`cluster.tf`'s `omnictl_machine_labels` reconciler is reduced to syncing only `node.antinvestor.io/role` to Omni Machine labels. That's the one label `machine-classes.yaml` selectors match on. All other labels move to Talos `machine.nodeLabels` (Kubernetes Node scope, applied via the per-node patch).

This stops short of fully eliminating the Omni sync, which still needs `node.antinvestor.io/role` on Omni Machine inventory for MachineClass→MachineSet routing. The path to dropping it entirely (kernel-cmdline initial-labels at image-mint time) is documented as a TODO in `tofu/shared/clusters/main.yaml` and remains a future PR.

### Data flow

```
Contabo provider response                    OCI VNIC data source
  ip_config[0].v{4,6}[0].{ip,                  oci_core_instance.this.public_ip
    netmask_cidr,gateway}                       data.oci_core_vnic.primary.ipv6addresses[0]
        │                                              │
        ▼                                              ▼
node-contabo outputs                          node-oracle outputs
  ipv4, ipv4_cidr, ipv4_gateway                 ipv4, public_ipv4, ipv6
  ipv6, ipv6_cidr, ipv6_gateway                 derived_labels, derived_annotations
  derived_labels, derived_annotations             (incl. flannel public-ip overrides)
        │                                              │
        └──────────────────┬───────────────────────────┘
                           ▼
              layer 03 reads node outputs
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
    Render node-contabo.tftpl     Render node-oracle.tftpl
              │                         │
              └────────────┬────────────┘
                           ▼
        Wrap each in ConfigPatches.omni.sidero.dev envelope
        named `stawi-<node>-link`, scoped to the matching machine ID
                           │
                           ▼
        Write each to R2: production/per-node-patches/<talos-version>/<node>.yaml
                           │
                           ▼
       sync-cluster-template.yml workflow:
         1. omnictl cluster template sync (cluster patches → all machines)
         2. omnictl apply (per-node patches → matching machine)
         3. orphan sweep: delete stawi-*-link patches whose <node> not in current set
```

### Why this carving

- **Layer 03 owns rendering** because that's the only place with cross-provider node state assembled into one map (`local.all_nodes_from_state`). Rendering in-layer keeps the workflow ignorant of node topology.
- **R2 owns the rendered artifacts** (Q1=b) because (i) it survives tofu-state-rebuild, (ii) it mirrors how `node-state` already writes per-node Talos configs to R2 under `<account>/<talos-version>/`, and (iii) the workflow reads R2 anyway for the cluster-state sweep filter.
- **Workflow owns the apply** because the workflow already authenticates to Omni via `OMNI_SERVICE_ACCOUNT_KEY` and uses `omnictl` for cluster template sync and label reconciliation.
- **Two templates, not one polymorphic** because their content shapes differ enough (LinkConfig vs no LinkConfig) that branching inside one template is harder to read than two parallel files.

## Components: files to add, modify, remove

### Add

- **`tofu/shared/patches/link-alias.yaml`** — single-doc cluster-wide LinkAliasConfig.
- **`tofu/shared/patches/node-contabo.tftpl`** — per-Contabo-node template: `machine.nodeLabels` + `machine.nodeAnnotations` + `LinkConfig name: wan0` + `HostnameConfig`.
- **`tofu/shared/patches/node-oracle.tftpl`** — per-OCI-node template: `machine.nodeLabels` + `machine.nodeAnnotations` (incl. flannel public-ip overrides) + `HostnameConfig`.
- **`tofu/layers/03-talos/per-node-patches.tf`** — `for_each` over `local.all_nodes_from_state`; branches on `v.provider`: `contabo` → render `node-contabo.tftpl`, `oracle` → render `node-oracle.tftpl`, `onprem` → skip. Writes each rendered **Talos** patch (NOT yet wrapped in the Omni envelope) via `aws_s3_object` to R2 path `production/per-node-patches/<talos-version>/<node>.yaml`. Uses a layer-local `aws_s3_object` rather than extending `node-state` because the R2 path is cluster-scoped (top-level), not account-scoped — outside `node-state`'s `<account>/<talos-version>/` key shape.

- **`tofu/layers/03-talos/scripts/apply-per-node-patches.sh`** — workflow-invoked script that, for each per-node patch in R2: (1) resolves machine-id via Omni using the hostname-then-ipv4 matching logic already used by `sync-machine-labels.sh`, (2) wraps the Talos patch content in a `ConfigPatches.omni.sidero.dev` envelope (id = `stawi-<node>-link`, machine label = the resolved id), (3) `omnictl apply` the wrapped manifest. Sibling to `sync-machine-labels.sh`; reuses the same matching pattern. Owning the envelope wrapping in the apply step — not in tofu — sidesteps the chicken-and-egg of needing machine-ids at plan time.

### Modify

- **`tofu/modules/node-contabo/main.tf`** — extend `locals` with:
  ```hcl
  ipv4_cidr    = contabo_instance.this.ip_config[0].v4[0].netmask_cidr
  ipv4_gateway = contabo_instance.this.ip_config[0].v4[0].gateway
  ipv6_cidr    = try(contabo_instance.this.ip_config[0].v6[0].netmask_cidr, null)
  ipv6_gateway = try(contabo_instance.this.ip_config[0].v6[0].gateway, null)
  ```
  Add precondition: when `var.role` is non-empty, all four must be non-empty/non-null — fail plan rather than render an invalid LinkConfig.

- **`tofu/modules/node-contabo/outputs.tf`** — extend the `node` contract with `ipv4_cidr`, `ipv4_gateway`, `ipv6_cidr`, `ipv6_gateway`.

- **`tofu/modules/node-oracle/outputs.tf`** — extend the `node` contract with `public_ipv4` (= `oci_core_instance.this.public_ip`, distinct from the existing `ipv4` which falls back to private). Render skips the flannel `public-ip-overwrite` annotation when `public_ipv4` is null/empty.

- **`tofu/shared/clusters/main.yaml`** — two edits in the `patches:` block:
  1. Add `link-alias` patch reference.
  2. Flip `dual-stack` patch subnet ordering to IPv6-first (per the snippet in Architecture/A.2).

- **`tofu/layers/03-talos/cluster.tf`** — narrow the `omnictl_machine_labels` reconciler's label set to only the role label. The surrounding envelope (which carries `ipv4` for the hostname-then-ipv4 machine-matching fallback) is unchanged — only the `labels` map shrinks:
  ```hcl
  omni_machine_apply_per_node = {
    for k, v in local.all_nodes_from_state : k => {
      labels = {
        "node.antinvestor.io/role" = try(v.derived_labels["node.antinvestor.io/role"], null)
      }
      ipv4 = try(v.ipv4, null)
    }
  }
  ```
  Add a comment explaining: K8s Node labels moved to Talos `machine.nodeLabels` (per-node patches), Omni Machine labels narrowed to selector-required only, full elimination tracked in the existing TODO.

- **`.github/workflows/sync-cluster-template.yml`** — restore the per-node-patch render+apply step (deleted in `7c7b6cd`):
  1. Pull each rendered patch from R2 (`production/per-node-patches/<talos-version>/*.yaml`).
  2. `omnictl apply -f <file>` per file. Order: cluster template sync → per-node apply → orphan sweep.
  3. Replace the existing legacy-cleanup step with a *targeted* orphan sweep: list all `ConfigPatches.omni.sidero.dev` matching `stawi-*-link`, delete only those whose `<node>` segment is not in the current tofu node set. Apply-then-sweep ordering ensures we don't nuke what we just applied.

### Remove

Nothing deleted outright. The retired patch files are recreated (with fixes); the legacy-cleanup workflow step is replaced by the targeted-orphan-sweep above.

## Testing & validation

### Pre-apply

- **Tofu plan inspection** shows one rendered patch per Contabo + OCI node, none for on-prem. Each Contabo patch's `routes[].gateway` ≠ that node's own addresses (the `490ae67` regression check, visible in plan diff).
- **`talosctl validate -m metal -c <file>`** per rendered patch via `null_resource.local_exec`. Catches schema errors before they hit Omni.
- **`omnictl cluster template validate -f main.yaml`** validates the new `link-alias` patch's CEL expression and the IPv6-first dual-stack patch.

### Post-apply (per node)

1. `talosctl get linkalias --nodes <node>` — expect `wan0` resolved to a real link with `link.type=ether`.
2. `talosctl get addresses --nodes <node>` — expect both v4 and v6 on `wan0` (Contabo) or on the platform-default link (OCI).
3. `talosctl get routes --nodes <node>` — expect one v4 default and one v6 default; v6 gateway ≠ node's own v6 address.
4. `talosctl get hostnamestatus --nodes <node>` — hostname matches inventory, `auto: off`.
5. `kubectl get node <node> -o jsonpath='{.metadata.labels}'` — contains `node.antinvestor.io/role`, `node-role.kubernetes.io/worker` (or `control-plane`), and the rest of `derived_labels`.
6. `kubectl get node <node> -o jsonpath='{.metadata.annotations}'` — for OCI nodes, contains `flannel.alpha.coreos.com/public-ip-overwrite` matching the ephemeral public IP.

### Post-apply (cluster)

1. `kubectl get nodes -o wide` — every node reports both v4 and v6 InternalIP.
2. Dual-stack pod gets both v4 and v6 podIPs.
3. ClusterIP service with `ipFamilyPolicy: PreferDualStack` gets both v4 and v6 ClusterIPs.
4. **Regression check for `490ae67`'s root cause:** `kubectl logs -n kube-flannel ds/kube-flannel | grep -i "default v6"` — expect no `failed to get default v6 interface` errors.
5. **Regression check for OCI VXLAN:** create a busybox pod on Contabo and another on OCI; `kubectl exec` from one to the other's pod IP. Cross-provider pod-to-pod traffic must work — that's the test that proves the flannel public-ip override is live.

### Rollout strategy

- **Order**: cluster patches before per-node patches (the alias must exist before any `LinkConfig name: wan0` lands). Workflow step ordering enforces this.
- **First node canary**: apply with a `target_nodes` workflow input filter set to one Contabo worker (proposed: `contabo-bwire-node-3`). Run all post-apply checks. Then re-run with the filter cleared.
- **Bail-out**: per-node revert is `omnictl delete configpatch stawi-<node>-link` — restores cluster-default networking for that node. No rebuild required.

## Risks & open questions

### Risks

- **R1: Contabo Private Networking add-on breaks the universal alias.** A second virtio_net NIC would make `link.type == "ether"` match twice, with non-deterministic enumeration order. Mitigation: documented in the `node-contabo.tftpl` header comment; per-node MAC-pinned `LinkAliasConfig` override available via the per-node patch when needed. Detection: post-apply `talosctl get linkalias` shows >1 alias for that node.
- **R2: Cluster-wide alias must propagate before per-node `LinkConfig` is applied.** Workflow step ordering (cluster template sync first, per-node apply second) handles this. Documented in the workflow as an explicit ordering dependency, not incidental.
- **R3: Empty `gateway` from a freshly-created Contabo instance.** Mitigated by the `precondition` on `node-contabo` outputs that fails plan when role is set but any of the v4/v6 ip/cidr/gateway fields are empty.
- **R4: IPv6-first ordering may break workloads that pick the first IP and expect v4.** Reversibility: flip `main.yaml` and re-sync. Watch list: any operators that don't explicitly handle dual-stack.
- **R5: First propagation of K8s labels/annotations may surprise.** Workloads that rely on absent labels (e.g. `node-role.kubernetes.io/worker` not being set) may behave differently. Eyeball `kubectl get nodes --show-labels` post-apply on the canary.

### Out of scope (deferred)

- **Kernel-cmdline initial-labels at image-mint time** — would let us drop `cluster.tf`'s Omni machine-label sync entirely. Tracked in the existing TODO in `tofu/shared/clusters/main.yaml`.
- **On-prem (`onprem-tindase-node-1`)** — currently out of scope per the 2026-05-03 realignment. The renderer skips on-prem nodes regardless; if `tindase` returns to scope later, the cluster-wide `link.type == "ether"` selector still works for single-NIC on-prem; multi-NIC on-prem would need a per-node MAC-pinned override.
- **`ResolverConfig` per-host** — kept cluster-wide at `tofu/shared/patches/resolvers.yaml`. The Ansible role's per-host emission is functionally equivalent; no benefit to changing scope.
- **KubeSpan / Flux extraManifests reintroduction** — separate PRs per the existing notes in `main.yaml`.
