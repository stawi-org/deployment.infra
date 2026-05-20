# Split cluster DNS into its own layer — design

> **Date:** 2026-05-20
> **Scope:** Carve `prod.<zone>` LB round-robin DNS out of `03-talos` into a new `04-dns` layer. Leave `00-omni-server`'s `cp/cpd` records untouched.
> **Posture:** Behaviour-preserving migration. No record-set change. Drift handled by lifting the existing self-heal verbatim.

## Goal

A node-provisioning apply no longer fails on Cloudflare DNS drift. A DNS-API failure no longer blocks Talos config apply. Adding a node only touches DNS state if the node carries `node.kubernetes.io/external-load-balancer=true`.

## Why

`03-talos/dns.tf` couples three responsibilities into one layer:
1. Apply Talos machine configs over the cluster network (apid / Omni gRPC).
2. Sync per-machine labels into Omni (`local-exec` `omnictl`).
3. Maintain `prod.<zone>` A/AAAA round-robin across LB-tagged nodes via the Cloudflare provider.

A failure in (3) — most recently `code 81058 "identical record already exists"` from CF when an existing record isn't in tofu state — fails the whole layer and blocks (1) and (2). The 2026-05-20 `allanofwiti` onboarding exposed this even though the new node has `external-load-balancer=false` and contributes nothing to `prod.<zone>` — `03-talos` re-evaluates the whole DNS block on every apply, so any pre-existing drift bites.

The `kube-controller-manager` crash-loop, missing app-secrets, and other observed brittleness are separate failure modes; this design addresses only the DNS coupling.

## Non-goals

- Touching `00-omni-server`'s `cp.<zone>` / `cpd.<zone>` records. Those already have working drift-self-heal and are substrate-agnostic.
- Replacing tofu-managed DNS with ExternalDNS. Larger investment; left as a follow-up if 04-dns proves insufficient.
- Per-account DNS state. The record set is global (one A/AAAA round-robin), so per-account would just add coordination overhead with no isolation benefit.
- Rewriting `03-talos`'s per-instance error classification (`cp_keys` / `worker_keys`). Worth doing eventually; out of scope here.

## Architecture

### Layer placement

New layer `tofu/layers/04-dns/` runs after `03-talos`, in parallel with `04-flux`. Both depend on `03-talos`; neither depends on the other.

```
secrets ──┬─→ contabo-infra ──┐
          ├─→ oracle-infra ───┼─→ oci-storage ─┐
          └─→ onprem-infra ───┘                ├─→ 03-talos ──┬─→ 04-dns
                                                ┘              └─→ 04-flux
```

Sibling `04-X` layers are fine (we already have multiple `02-X`). tofu does not care about numeric prefixes; the directory name is the identity.

### State

Single tfstate at `s3://cluster-tofu-state/production/04-dns.tfstate`. No per-account fan-out — record set is global.

### Provider

`cloudflare` only. Re-uses the existing `cloudflare_api_token` (`Zone:DNS:Edit` on the zones in `cp_dns_zones`) currently consumed by `03-talos` and `00-omni-server`. No scope change.

## Components

### `tofu/layers/04-dns/main.tf`

- `provider "cloudflare"` with `api_token = var.cloudflare_api_token`.
- `data "terraform_remote_state" "contabo"` / `"oracle"` / `"onprem"` — identical to `03-talos/main.tf` lines 20–95. Assembles `all_nodes_from_state` (the same map talos uses).
- Computes `local.lb_nodes` (filter by `external-load-balancer=true`), `lb_all_ipv4`, `lb_all_ipv6`.

### `tofu/layers/04-dns/dns.tf`

The body of today's `03-talos/dns.tf` (lines 23–182), lifted verbatim. Logic unchanged:
- `module "cluster_dns"` (`../../modules/cloudflare-dns`) — writes per-zone A/AAAA round-robin.
- `data "cloudflare_dns_records" "existing_per_zone"` + `import` block — drift adoption. IPv6 canonicalisation via `cidrhost("${ip}/128", 0)` preserved.
- `_debug_dns_intended_canonical_keys` / `_debug_dns_existing_canonical_keys` / `_debug_dns_to_import` outputs preserved.

### Stale-record cleanup — deferred to follow-up

Original design called for an in-layer `destroy.tf` that reaped CF records belonging to demoted LB workers. On closer inspection of tofu semantics, the obvious patterns each have material drawbacks:

- **`import` + no resource declaration** — tofu rejects `import` blocks whose target resource isn't declared in config.
- **`import` + `removed` block on the same address** — same-PR coexistence is disallowed; requires a 2-PR sequence (PR1 adopts, PR2 declares removed).
- **`null_resource` + `local-exec curl DELETE`** — works in one PR but the destroy command is hidden in a triggers map, far less reviewable than a native plan diff.

Doing this right is a separate plan (likely the 2-PR adopt-then-remove sequence, or a small custom provider). Deferred so this PR stays focused on the layer split + failure isolation, which is the load-bearing improvement.

**Interim workaround:** operators delete demoted records from the Cloudflare dashboard when a worker is demoted. Low frequency in practice (LB-tag changes are deliberate operator actions).

**Tracked as:** follow-up issue / plan to be created after this PR merges.

### `tofu/layers/04-dns/variables.tf`

Three vars (copies of `03-talos`'s):
- `cloudflare_api_token` (sensitive)
- `cp_dns_zones` (list of `{ zone_id, zone, prod_label }`)
- `r2_account_id`

### `tofu/layers/04-dns/versions.tf`

`required_providers` for `cloudflare` and `aws` (R2 backend). No `talos`, `omni`, `oci`, `contabo` — DNS does not need them.

### Removed from `03-talos`

- `tofu/layers/03-talos/dns.tf` — whole file.
- `cloudflare` provider block in `03-talos/versions.tf`.
- `cloudflare_api_token` and `cp_dns_zones` variables in `03-talos/variables.tf` (verified no remaining consumers in `03-talos` after `dns.tf` is removed — grep returns no hits).

### `.github/workflows/tofu-apply.yml` + `tofu-plan.yml`

New job `dns`, identical shape to the existing `flux` job:

```yaml
dns:
  needs: talos
  uses: ./.github/workflows/tofu-layer.yml
  with:
    layer: 04-dns
    mode: apply
    environment: production
  secrets: inherit
```

`tofu-plan.yml` gets the matching `dns` plan job.

### Lifecycle hardening

Add `lifecycle { create_before_destroy = true }` on `cloudflare_dns_record.this` inside `modules/cloudflare-dns/main.tf`. An IP change becomes (create new record) → (delete old) instead of (delete) → (create), avoiding a brief NXDOMAIN window.

## Data flow

### One-time migration (first apply after merge)

1. `03-talos` apply runs. `dns.tf` has been deleted, but a transitional `removed.tf` declares `removed { from = module.cluster_dns lifecycle { destroy = false } }`. Tofu drops `module.cluster_dns` from `03-talos`'s tfstate without making any Cloudflare API calls — the records remain live in CF.
2. `04-dns` apply runs for the first time. Plan shows N record creates. CF returns `400 81058 "identical record already exists"` on each. The `import` block fires from `data "cloudflare_dns_records"` lookup. Records adopt into `04-dns`'s tfstate. Subsequent applies are no-op.
3. Follow-up commit (after the first successful apply cycle): delete `03-talos/removed.tf`. The `removed` block has done its job; leaving it in place is harmless but cluttered.

The migration leans on two tofu-native primitives: `removed { destroy = false }` for the departure from `03-talos`, and the existing `import` self-heal for the arrival at `04-dns`. No `tofu state mv` / `tofu state rm` operator surgery required.

### Steady state

1. Infra layers (01/02) update per-account `nodes.yaml` on R2 with new `provider_data.ipv4/ipv6` blocks.
2. `03-talos` reads infra remote states, renders + applies Talos machine configs. Succeeds or fails independently of DNS.
3. `04-dns` reads the same infra remote states, recomputes `lb_nodes`, diffs vs CF, applies record changes. Succeeds or fails independently of talos.

### Node-add flow (`allanofwiti`-style)

- New node lands with `external-load-balancer: "false"` (default).
- `04-dns` plan shows no changes. No DNS apply happens. Zero blast radius for DNS.
- Operator later flips the label → plan shows one A + one AAAA add → apply runs only those.

### Failure-isolation matrix

| Failure | `03-talos` | `04-dns` | `04-flux` | Cluster state |
|---|---|---|---|---|
| Cloudflare API 5xx | unaffected | fails | unaffected | fully functional, DNS stale |
| CF record drift (today's bug) | unaffected | fails first apply, self-heals on retry | unaffected | as above |
| Talos apid unreachable | fails | unaffected | unaffected | DNS still updates correctly |
| Omni proxy down | `omnictl_machine_labels` step fails | unaffected | unaffected | DNS still updates |
| Stale records pile up after demotion | unaffected | unaffected (cleanup deferred to follow-up) | unaffected | DNS carries demoted IPs until operator deletes via CF dashboard |

## Robustness additions

1. **Pre-apply drift surfacing in CI** — `tofu-plan.yml`'s `04-dns` job adds a step that runs `tofu show -json plan.tfplan | jq '.resource_changes[] | select(.change.actions[] != "no-op")'` and emits the change list as a GitHub annotation. Operators see "will create 3, import 2, destroy 0" on the PR before merging.
2. **`create_before_destroy`** on `cloudflare_dns_record.this` — IP changes don't briefly NXDOMAIN.
3. **Per-record granularity preserved** — `for_each` keying means a CF rate-limit or 5xx on record X fails only X's resource, not the whole layer.
4. **Stale-record cleanup** — see deferred section above; tracked as follow-up.

## Testing

- **tflint + trivy** on `04-dns` sources (pre-commit hooks already cover `tofu/layers/**`).
- **`tofu validate` + `tofu plan`** on `04-dns` in CI via the existing per-layer plan-on-PR pattern.
- **Migration dry-run** — operator runs `tofu plan` locally against `04-dns` with live R2 state before merging; inspects `_debug_dns_to_import` output to confirm every existing `prod.<zone>` record resolves to an import. If a record is unresolved, hand-import it before applying.
- **Post-merge verification**:
  - `gh workflow run tofu-apply` → 04-dns job succeeds.
  - `dig prod.stawi.org A +short` and `dig prod.stawi.org AAAA +short` return the expected IP sets.
  - Demote one LB worker (label flip), re-apply, confirm the demoted IPs are removed (validates the stale-record cleanup).

## Migration risks + mitigations

| Risk | Mitigation |
|---|---|
| First 04-dns apply fails because import-block lookup misses a record | `_debug_dns_*` outputs make the diff visible. Operator hand-imports the missing record and re-applies. |
| 03-talos's tfstate or CF would lose records during migration | `removed { from = module.cluster_dns lifecycle { destroy = false } }` in a transitional 03-talos `removed.tf` drops state without touching CF; 04-dns's import-block adopts on its first apply. |
| Cloudflare API token scope insufficient | Same token already used by `03-talos` for the same zone. No scope change. |
| Concurrent CF write between plan and apply | Standard tofu race. Worst case: apply fails, drift handler picks it up next run. |
| Plan-time-known constraints break (e.g. data source returns empty) | Existing `try()` coercions in the lifted dns.tf already handle this — `to_import` becomes `{}` and the import block is a no-op. |

## Out of scope (separate work items)

- `kube-controller-manager` on `contabo-bwire-node-2` crash-loop. Pre-existing CP redundancy issue.
- Missing app-secrets (`db-credentials-*`, `ghcr-auth`). Flux / external-secrets config, not infra.
- `03-talos`'s per-instance error classification. Tightening the contract between `02-*-infra` and `03-talos` (e.g. machine-readiness gate from Omni state) would let us delete the classification logic; bigger refactor.
- ExternalDNS migration. If 04-dns still proves brittle after this PR, revisit.

## Success criteria

| Criterion | Verification |
|---|---|
| `03-talos` apply no longer touches Cloudflare | `grep cloudflare tofu/layers/03-talos/` returns nothing |
| Adding a non-LB node produces no-op `04-dns` plan | Onboard a sandbox account; `tofu plan` shows 0 changes in 04-dns |
| CF drift on `prod.<zone>` self-heals via 04-dns | Delete a managed record manually; next 04-dns apply re-imports it |
| A `04-dns` failure does not block `04-flux` | Inject CF 401 via env override; confirm `04-flux` job still runs |
