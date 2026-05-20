# Narrow 03-talos label sync to changed machines only — design

> **Date:** 2026-05-20
> **Scope:** Replace `null_resource.omnictl_machine_labels` (singleton, runs across all machines on any inventory delta) with `null_resource.omnictl_machine_label["<node_name>"]` (per-machine via `for_each`).
> **Posture:** Behaviour-preserving refactor. Same labels applied, same script logic, same Omni resource model. Only the granularity changes.

## Goal

`tofu plan` for `03-talos` shows zero diff in steady state. Adding a node creates exactly one new resource; existing-node resources are untouched and don't re-poll Omni. Changing one node's role re-keys exactly one resource. Bug-fixing the script or changing `omni_endpoint` is the only operation that fans out to all instances.

## Why

`null_resource.omnictl_machine_labels` is keyed on `sha256(jsonencode(local.all_nodes_from_state))`. Any node attribute change — new node, IP change, OCI instance OCID rotation — re-keys the trigger and replaces the resource. The provisioner then re-enters its polling loop (up to 15 minutes waiting for every expected machine to register) before applying labels to *all* machines. With `7-8 expected nodes`, that's ~15 min wall time on every inventory change, even when only one node's labels actually moved.

This couples node-add/change cadence to label-sync cadence across the whole fleet. The DNS split (PR #252) removed one coupling; this removes the other major one inside `03-talos`.

The longer-term retirement path — baking the two labels (`node.antinvestor.io/role`, `node.antinvestor.io/name`) into kernel cmdline at image-mint time — is tracked separately as a TODO in `tofu/shared/clusters/main.yaml`. This design is the intermediate improvement, not the final state.

## Non-goals

- Retiring the reconciler entirely. That's the kernel-cmdline route; bigger change, separate plan.
- Changing which labels get synced (still just the two: role + name).
- Touching the Contabo / Oracle / onprem infra modules. The per-node `derived_labels` computation in those modules is unchanged.
- Replacing `omnictl apply` with a different Omni API path.

## Architecture

### Resource shape

Singleton → for_each:

```hcl
# Before
resource "null_resource" "omnictl_machine_labels" {
  triggers = { ...sha of all nodes... }
  provisioner "local-exec" { runs sync-machine-labels.sh against full JSON }
}

# After
resource "null_resource" "omnictl_machine_label" {
  for_each = local.omni_machine_apply_per_node
  triggers = { labels_sha = ..., ipv4 = ..., script_sha = ..., endpoint = ..., cluster = ..., retry_token = ... }
  provisioner "local-exec" { runs sync-machine-label.sh against one node }
}
```

Singular name change (`labels` → `label`) reflects the per-instance semantic.

### Triggers

Per instance:
- **`labels_sha`** — `sha256(jsonencode(each.value.labels))`. Changes only when this node's label *content* changes (operator edits role).
- **`ipv4`** — the node's IPv4 (literal). Changes when the OCI VM gets a new public IPv4 after destroy+create, which invalidates the IP-based machine match.
- **`script_sha`** — `filesha256(local.sync_machine_label_path)`. Shared across all instances. Bug-fixing the script fans out to all (correct behaviour).
- **`endpoint`** / **`cluster`** — `var.omni_endpoint`, `var.cluster_name`. Shared. Changing the Omni target re-syncs the fleet (correct).
- **`retry_token`** — `var.label_sync_retry_token` (new var, default `""`). Operator-only manual escape hatch. Bumping it re-keys all instances. Same role as `force_reinstall_generation` in the infra layers — used after a timeout-skip to force a re-attempt without inventing other inputs.

### Per-machine provisioner

`sync-machine-label.sh` (new file) takes one node via env:
- `NODE_NAME` — `each.key`.
- `NODE_LABELS_JSON` — `jsonencode(each.value.labels)` (compact JSON object).
- `NODE_IPV4` — `each.value.ipv4` or empty string.
- `OMNI_CLUSTER`, `OMNI_ENDPOINT`, `OMNI_SERVICE_ACCOUNT_KEY` — same as today.

Logic:
1. If `NODE_LABELS_JSON` is `{}` → log no-op, exit 0.
2. Poll `omnictl get machinestatus` up to 15 minutes, matching by hostname=NODE_NAME OR any address (CIDR-stripped) == NODE_IPV4.
3. On match → render `MachineLabels.omni.sidero.dev` manifest with `metadata.labels = $NODE_LABELS_JSON` and `metadata.id = $machine_id` → `omnictl apply -f`. Exit 0.
4. On poll timeout → log WARN ("registration wait timed out — skipping"), exit 0. Operator triggers a retry by bumping `label_sync_retry_token` or by changing some other input.

Per the answered design question, timeout exits 0 to avoid noisy CI failures when one machine is temporarily down. The cost of the trade-off is that a missed-machine doesn't auto-retry on the next apply unless inputs change; mitigation is the `retry_token` knob.

### Files changed

**Modify:**
- `tofu/layers/03-talos/cluster.tf` — replace the resource block (lines 86-124), delete the no-longer-needed `local_sensitive_file.node_labels_json` resource and the `sync_machine_labels_path` local.
- `tofu/layers/03-talos/variables.tf` — add `label_sync_retry_token` variable (string, default `""`).

**Create:**
- `tofu/layers/03-talos/scripts/sync-machine-label.sh` — new per-machine script.

**Delete:**
- `tofu/layers/03-talos/scripts/sync-machine-labels.sh` — bulk script, superseded.

### Data flow

**Steady state** — no inventory changes:
- All triggers stable. `tofu plan` shows zero changes.

**Add a new node** (e.g. retry ambetera, or a new account onboarding):
- Inventory grows by one entry.
- `for_each` picks up the new key. Plan: `+ null_resource.omnictl_machine_label["<new-node>"]`. Other instances unchanged.
- Apply: only the new instance's provisioner runs. Existing 7 machines untouched, no re-polling.

**Change role on an existing node:**
- Inventory edit changes `derived_labels["node.antinvestor.io/role"]` for that node.
- `labels_sha` trigger changes for that one instance. Plan: `~ null_resource.omnictl_machine_label["<node>"]`. Other instances unchanged.

**OCI VM destroy+create** (e.g. force-reinstall, image roll):
- New IPv4 → `ipv4` trigger changes for that instance only. Resource replaces. Others unchanged.
- The new machine's MachineLabels (keyed on the new Omni machine ID after re-registration) gets a fresh apply.

**Script bug-fix:**
- `script_sha` shared trigger changes → all instances re-key → all re-run.
- Acceptable: a script-level fix genuinely needs to be replayed across the fleet.

**Endpoint or cluster change:**
- Shared trigger changes → fleet-wide re-run. Same rationale.

**Operator manual retry:**
- Bump `label_sync_retry_token` → fleet-wide re-run.
- Used after a timeout-skip when a previously-missing machine has come up but no other input changed.

### Failure handling

Per-instance polling timeout: log WARN, exit 0. Tofu marks the resource created. No automatic retry on subsequent applies unless inputs change.

`omnictl apply` failure inside the provisioner (e.g. transient Omni 500): exit non-zero. Tofu marks the resource creation as failed. Next apply retries that one instance only.

Per-machine failures are isolated — one machine's `omnictl apply` failing does not block other instances (tofu runs `null_resource` instances in parallel up to `-parallelism=10`).

### Concurrency

Tofu's default `-parallelism=10` means up to 10 instances run their provisioners concurrently. Each polls `omnictl get machinestatus` (one API call per poll loop iteration per machine). With 8 machines and 15-minute timeouts, worst case is 8 concurrent polling loops × ~60 calls each = ~480 calls over 15 minutes. Omni handles that easily.

No per-machine state coordination needed because `MachineLabels` resources are keyed by machine ID — concurrent `omnictl apply` calls on different machine IDs don't conflict.

## Migration

Resource address change (`null_resource.omnictl_machine_labels` → `null_resource.omnictl_machine_label["<node>"]`) cannot be represented by `moved {}` blocks because tofu's `moved` requires one-to-one source/destination mapping. The 1 → N case is unsupported.

Two acceptable paths:

**Path A (chosen): destroy + recreate.** The first apply after merge destroys the singleton and creates N per-machine instances. Each instance's provisioner runs (8 instances on this cluster, all idempotent — same labels applied as before). One-time cost: ~1 minute per machine in the worst case, fully parallel. Net wall time: same as one current sync. Subsequent applies see zero diff.

**Path B (not chosen): operator-run `tofu state mv` per instance.** Avoids the script re-run but requires 8 `state mv` commands on the operator's local checkout. Higher operator burden for marginal gain (~1 minute saved on the migration apply).

The migration apply is logged in the PR's `tofu-plan` job as `1 to destroy, 8 to add` (or N per the actual node count at merge time). Operators see the shape before merging.

## Testing

- **`tofu validate`** on 03-talos after the change.
- **`tofu plan`** locally with live state pulled from R2 — confirm the plan shows `1 to destroy, N to add` (where N = current node count). No other resources change.
- **Post-merge apply** — confirm all N instances complete (applied=N, errored=0 in workflow logs). Confirm subsequent `tofu plan` shows zero diff.
- **Behaviour test** — bump a node's role in inventory; confirm `tofu plan` shows exactly one instance changing. Apply; confirm `omnictl` shows the updated label on that one machine only.
- **No-op test** — re-run `tofu plan` immediately after apply with no inventory change; confirm zero diff.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Migration apply re-runs the script for all machines, adding ~1 min/machine wall time | One-time cost, expected, documented in PR |
| Per-machine polling timeout silently skips a machine | Operator-visible WARN in logs; `label_sync_retry_token` knob for explicit retry; cluster-health check catches "in inventory but not in MachineSet" symptoms |
| Per-instance script could shadow a bulk-script bug fix | `script_sha` trigger is shared — bug fixes fan out as today |
| Parallel `omnictl get machinestatus` calls hit Omni rate limits | Default parallelism cap of 10; each call is read-only; Omni's machinestatus endpoint is not rate-limited in practice |
| `for_each` key collision if two accounts produce the same `node_name` | Node names already enforced unique via the `<provider>-<account>-node-N` convention; same constraint as today |

## Out of scope (separate work)

- Retiring this reconciler entirely via kernel-cmdline labels (the TODO in `tofu/shared/clusters/main.yaml`). Bigger change touching the image-mint pipeline.
- Cross-machine label dependencies (e.g. "promote second-oldest worker to CP automatically"). Today's labels are purely local-per-node; this design preserves that.
- Annotations sync. The current reconciler does labels only; this design doesn't change that.

## Success criteria

| Criterion | Verification |
|---|---|
| Adding a non-LB worker produces a 1-resource plan in 03-talos | Test by re-adding ambetera once OCI capacity returns; plan shows `+ null_resource.omnictl_machine_label["oci-ambetera-node-1"]` only |
| Existing-node resources don't replace on unrelated node add | Same test as above; other 7 instances unchanged |
| `tofu plan` in steady state shows zero diff | Run `tofu plan` immediately after a successful apply; confirm "No changes." |
| Timed-out machines emit operator-visible WARN | Inspect provisioner log; line `[sync-machine-label] WARN <node>: registration wait timed out — skipping` |
| Retry knob works | Bump `label_sync_retry_token`; plan shows all instances replacing |
