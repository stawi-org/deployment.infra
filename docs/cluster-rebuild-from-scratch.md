# Cluster Rebuild From Scratch

How to rebuild the `stawi` cluster end-to-end and reach a working
IPv6-first dualstack state.

This runbook covers the full path from an empty Omni server (or a
broken cluster you want to nuke) to `Cluster RUNNING Ready (5/5)`
with IPv6 binding on every Contabo node and Flannel v6 pod networks
distributed across the cluster.

## Prerequisites

- Omni server up at `https://cp.stawi.org`. If `/var/lib/omni` was
  wiped, machines need new SideroLink registrations — bump
  `force_reinstall_generation` in
  `tofu/layers/01-contabo-infra/terraform.tfvars` and the equivalent
  knob in `02-oracle-infra/terraform.tfvars` so VPSes reinstall
  against the new omni-host's master key.
- GitHub repo secrets present: `OMNI_SERVICE_ACCOUNT_KEY` (Admin role
  in Omni), Contabo OAuth (`CONTABO_CLIENT_*`, `CONTABO_API_*`), R2
  (`R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`, `R2_ACCOUNT_ID`), and
  the OCI WIF binding via repo OIDC.
- R2 inventory under `production/inventory/<provider>/<account>/
  nodes.yaml` declares the operator-intended node names, roles, and
  product IDs. If you're starting from a clean R2, hand-create the
  files via the `upload-inventory` workflow first.

## Step sequence

```
   ┌─────────────────────────┐
   │ 1. regenerate-talos-images
   │    → mints Omni-aware Talos image
   │    → uploads to R2 + per-account OCI buckets
   │    → opens bot/talos-images-bump PR
   └─────────────────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │ 2. merge bot/talos-images-bump PR
   │    → publishes new image OCIDs into
   │      tofu/shared/inventory/talos-images.yaml
   └─────────────────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │ 3. tofu-apply
   │    → 01-contabo-infra: PUT-reinstalls Contabo VPSes
   │      onto the new image; writes provider_data
   │      (ipv4 + ipv4_cidr + ipv4_gateway + ipv6 +
   │      ipv6_cidr + ipv6_gateway) into R2 inventory.
   │    → 02-oracle-infra: destroy+create OCI VMs.
   │    → 02-onprem-infra: skip (out of scope).
   │    → 03-talos: render per-node patches (ens18
   │      LinkConfig with both v4 + v6, HostnameConfig
   │      with canonical hostname) and upload to
   │      production/per-node-patches/<talos>/<node>.yaml.
   │      Also reconciles MachineLabels on each Omni
   │      Machine: node.antinvestor.io/{name,role,
   │      account,provider,...}.
   └─────────────────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │ 4. (only if cluster already exists)
   │    omni-force-cluster-clear (input confirm=stawi)
   │    → drops Cluster + ConfigPatches; keeps
   │      Machine resources so the next sync
   │      doesn't have to re-register every node.
   └─────────────────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │ 5. sync-cluster-template
   │    → applies cluster.yaml (Cluster + ControlPlane +
   │      Workers MachineSets + cluster-level patches:
   │      link-alias, dual-stack, ipv6-tuning).
   │    → bootstrap-bind: labels each unbound Machine
   │      with role=controlplane|worker from R2
   │      inventory.
   │    → apply-per-node-patches.sh: pulls each rendered
   │      per-node patch from R2 and creates a
   │      ConfigPatch resource bound via metadata.labels[
   │      omni.sidero.dev/cluster-machine]=<machine-uuid>.
   │    → polls `cluster template status` until Ready or
   │      8-min timeout (workflow fails otherwise).
   └─────────────────────────┘
                │
                ▼
   ┌─────────────────────────┐
   │ 6. verify
   │    → omni-cluster-status (manual workflow)
   │      — confirms HostnameStatus, addressstatus,
   │        kube-apiserver reachable.
   └─────────────────────────┘
```

## Failure modes and recovery

### Contabo IDP brute-force lockout (HTTP 401 invalid_grant)

Symptom: `tofu-apply` fails on the contabo-infra layer with
```
Contabo auth: HTTP 401 terminal. Body: {"error":"invalid_grant",
"error_description":"Invalid user credentials"}
```
even though the credentials are correct.

Cause: parallel `ensure_image` runs (one per VPS) hit Contabo's
KeyCloak account-lockout threshold within a short window. KeyCloak
holds the lockout for ~10 minutes.

Fix:
1. Wait at least 10 minutes (set a timer; don't keep retrying).
2. Bump `force_reinstall_generation` in
   `tofu/layers/01-contabo-infra/terraform.tfvars` (e.g. 17 → 18).
3. Re-run `tofu-apply`.

### Contabo VPS stuck after reinstall

Symptom: a VPS doesn't reconnect to Omni after a reinstall. Pingable
on its public IPv4 but `talosctl get` against its Machine ID via
`omnictl talosconfig` errors with `unreachable`.

Fix: dispatch `contabo-reboot-vps` with the affected `display_name`.
If the VPS is still stuck after a clean reboot, repeat with another
`force_reinstall_generation` bump.

### Per-node patches present in Omni but not applied to machines

Symptom: `omnictl get configpatches` shows the per-node patches
exist, but `talosctl get hostnamestatus` returns Contabo's platform
default (e.g. `vmi2727782`) and `talosctl get addressstatus` shows no
public IPv6 on `ens18`.

Cause: a regression of the 2026-05-06 selector bug. Omni's
`ConfigPatchSpec` does NOT have a `target_label_selectors` field —
it's silently dropped at unmarshal. Per-machine patches MUST bind
via `metadata.labels[omni.sidero.dev/cluster-machine]=<machine-uuid>`
(see `siderolabs/omni internal/backend/runtime/omni/controllers/
omni/internal/configpatch/configpatch.go:40-84`).

Fix: re-apply `tofu-apply` on layer 03-talos. The current
`apply-per-node-patches.sh` (post 2026-05-06) uses the right
selector — check the file hasn't been silently reverted.

### Cluster reaches `RUNNING` but stays `Not Ready`

Symptom: `cluster template status` shows the cluster RUNNING but
`controlplaneready: false` indefinitely.

Diagnostic: dispatch `omni-cluster-status` (manual workflow). Look
at:
- `Direct kube-apiserver probe (164.68.107.115:6443)` — if
  `Connection refused`, kube-apiserver static pod isn't running.
  Check `talosctl logs -k kube-apiserver` for the underlying error.
  The historical case: `service IP family must match public address
  family` when kubelet's nodeIP was IPv4 but cluster service range
  was IPv6-first. Fix: ensure the per-node `LinkConfig` is binding a
  v6 address on the CP (see "Per-node patches present but not
  applied" above) and that the cluster.yaml `dual-stack` patch puts
  the v6 service subnet first.
- `addressstatus` on the CP — must include the public v6 from the
  per-node LinkConfig, not just the SideroLink ULA + auto-link-local.

## Quick rebuild (cluster broken, infra healthy)

If only the cluster needs recreating (Talos / Omni / VPSes are all
up and connected), skip steps 1-3 and run:

```
gh workflow run omni-force-cluster-clear.yml -f confirm=stawi
gh workflow run sync-cluster-template.yml
gh workflow run omni-cluster-status.yml
```

The third call is a read-only health snapshot. Expect
`Cluster "stawi" RUNNING Ready (5/5)` within 5-8 minutes if the
infra side is healthy.

## Full rebuild (omni-host wiped, all VPSes need reinstall)

```
# 1. mint a fresh image schematic (regen-token bump in
#    tofu/shared/schematics/cluster.yaml is OPTIONAL — the workflow
#    detects schematic content changes and skips on no-op).
gh workflow run regenerate-talos-images.yml -f talos_version=v1.13.0

# 2. merge bot/talos-images-bump PR (auto-opened by step 1).

# 3. bump force_reinstall_generation in
#    tofu/layers/01-contabo-infra/terraform.tfvars (and also in
#    02-oracle-infra/terraform.tfvars if OCI VMs need new images).
#    Push to main.

# 4. tofu-apply applies all layers in order; 03-talos waits for
#    SideroLink re-registration before reconciling MachineLabels.
gh workflow run tofu-apply.yml

# 5. recreate the cluster.
gh workflow run omni-force-cluster-clear.yml -f confirm=stawi
gh workflow run sync-cluster-template.yml
```

End-to-end wall-clock: ~20-25 minutes if no IDP lockout, no Contabo
boot retries, and OCI image imports complete first try.

## Local kubectl access (after rebuild)

For day-to-day kubectl access from a workstation:

```
scripts/setup-kubectl.sh
```

The script is idempotent — installs `kubectl`, `kubelogin` (renamed
to `kubectl-oidc_login` because that's the executable name kubectl
looks for when handling OIDC plugin invocations), and `omnictl`,
points omnictl at `https://cp.stawi.org`, fetches an OIDC kubeconfig
into `~/.kube/config`, and runs `kubectl get nodes` to verify. First
run opens a browser for OIDC login; subsequent runs reuse the cached
token. Override versions / install dir via env vars at the top of
the script.

## Smoke test after rebuild

```
gh workflow run omni-cluster-status.yml
# Wait ~30s, then read the latest run.
# Expect:
#   Cluster "stawi" RUNNING Ready (5/5)
#   HostnameStatus on every node: canonical name, no vmi*
#   addressstatus on every Contabo node includes ens18/<v6>/64
#   kube-apiserver probe returns 401 (auth-required) — NOT 000/refused
```
