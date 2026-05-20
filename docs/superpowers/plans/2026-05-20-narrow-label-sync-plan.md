# Narrow 03-talos label sync to changed machines — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the singleton `null_resource.omnictl_machine_labels` in `03-talos` with `null_resource.omnictl_machine_label["<node>"]` keyed per-node, so adding or changing one node touches exactly one resource — not the whole fleet.

**Architecture:** `for_each = local.omni_machine_apply_per_node` on the null_resource. Per-instance triggers carry only that node's label sha + ipv4 + shared script/endpoint shas. A new per-machine script reads its target node from env (`NODE_NAME`, `NODE_LABELS_JSON`, `NODE_IPV4`), polls `omnictl get machinestatus` for that one machine, and applies a `MachineLabels.omni.sidero.dev` resource. The bulk script is deleted.

**Tech Stack:** OpenTofu ≥ 1.10 (existing in repo), `null_resource` with `for_each`, bash + `jq` + `omnictl` (already on the runner).

**Spec:** `docs/superpowers/specs/2026-05-20-narrow-label-sync-design.md`

---

## File map

**Create:**
- `tofu/layers/03-talos/scripts/sync-machine-label.sh` — per-machine reconciler.

**Modify:**
- `tofu/layers/03-talos/cluster.tf` — replace the resource block (lines ~80-124) with `for_each` shape. Delete `local_sensitive_file.node_labels_json` and the `sync_machine_labels_path` local.
- `tofu/layers/03-talos/variables.tf` — add `label_sync_retry_token` variable.

**Delete:**
- `tofu/layers/03-talos/scripts/sync-machine-labels.sh` (plural).

---

## Task 1: Create the new per-machine reconciler script

**Goal:** Standalone bash script that processes exactly one node when invoked. Reads `NODE_NAME`, `NODE_LABELS_JSON`, `NODE_IPV4` from env. Polls Omni up to 15 min for that one machine, applies `MachineLabels`, exits.

**Files:**
- Create: `tofu/layers/03-talos/scripts/sync-machine-label.sh`

- [ ] **Step 1: Create the feature branch**

```bash
git checkout main
git pull --ff-only
git checkout -b narrow-label-sync
```

- [ ] **Step 2: Create `tofu/layers/03-talos/scripts/sync-machine-label.sh`**

```bash
#!/usr/bin/env bash
#
# tofu/layers/03-talos/scripts/sync-machine-label.sh
#
# Per-machine reconciler. Called by null_resource.omnictl_machine_label
# in cluster.tf, once per node (via for_each). Polls Omni's
# machinestatus inventory up to REGISTRATION_TIMEOUT_SECS waiting for
# the target node to register, then applies a MachineLabels.omni.sidero.dev
# resource with the per-node labels passed in via env.
#
# Inputs (env):
#   NODE_NAME              Hostname of the target node (e.g. oci-bwire-node-1).
#   NODE_LABELS_JSON       Compact JSON object of labels to apply.
#                          Empty/null/{} is a documented no-op.
#   NODE_IPV4              IPv4 of the target node. Used as a fallback
#                          match against Omni's spec.network.addresses
#                          when hostname doesn't match (Contabo case).
#                          Empty string is OK; IPv4 match is skipped.
#   OMNI_ENDPOINT          omnictl reads this.
#   OMNI_SERVICE_ACCOUNT_KEY omnictl reads this.
#   OMNI_CLUSTER           Cluster name (used in log lines).
#   REGISTRATION_TIMEOUT_SECS (default 900) — poll wait for registration.
#   REGISTRATION_POLL_SECS   (default 15) — poll interval.
#
# Behaviour:
#   - Idempotent: `omnictl apply` upserts MachineLabels, so re-running
#     with same content is a no-op apply.
#   - Empty NODE_LABELS_JSON or {} → log + exit 0 (no-op).
#   - Poll-timeout (target not registered in time) → log WARN, exit 0.
#     Operator triggers a retry by bumping label_sync_retry_token.
#   - omnictl apply non-zero → log ERROR, exit non-zero (so tofu
#     marks this one instance's creation failed, and the next apply
#     retries this one instance only).

set -euo pipefail

[[ -n "${NODE_NAME:-}" ]] || { echo "[sync-machine-label] NODE_NAME not set" >&2; exit 1; }
[[ -n "${NODE_LABELS_JSON:-}" ]] || { echo "[sync-machine-label] NODE_LABELS_JSON not set" >&2; exit 1; }
[[ -n "${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "[sync-machine-label] OMNI_SERVICE_ACCOUNT_KEY unset" >&2; exit 1; }
command -v omnictl >/dev/null || { echo "[sync-machine-label] omnictl not in PATH" >&2; exit 1; }
command -v jq      >/dev/null || { echo "[sync-machine-label] jq not in PATH"      >&2; exit 1; }

readonly NODE_IPV4_VAL="${NODE_IPV4:-}"
readonly REGISTRATION_TIMEOUT_SECS="${REGISTRATION_TIMEOUT_SECS:-900}"
readonly REGISTRATION_POLL_SECS="${REGISTRATION_POLL_SECS:-15}"

# Validate the labels JSON parses, and short-circuit on empty.
if ! jq -e . >/dev/null 2>&1 <<<"$NODE_LABELS_JSON"; then
  echo "[sync-machine-label] $NODE_NAME: NODE_LABELS_JSON is not valid JSON — aborting" >&2
  exit 1
fi
label_count=$(jq -r 'length' <<<"$NODE_LABELS_JSON")
if [[ "$label_count" == "0" ]]; then
  echo "[sync-machine-label] $NODE_NAME: no labels to apply (empty map), exiting"
  exit 0
fi

# Fetch one snapshot of Omni machine inventory. NDJSON → array.
# Hardened against transient non-JSON output from omnictl (same shape
# as the prior bulk script).
fetch_machines() {
  local result
  result=$(omnictl get machinestatus --output json 2>/dev/null | jq -cs 'flatten' 2>/dev/null) || result=''
  if [[ -z "$result" ]] || ! jq -e . >/dev/null 2>&1 <<<"$result"; then
    result='[]'
  fi
  printf '%s' "$result"
}

# Match this one node to a machine ID. Hostname is the primary key
# (Omni picks up the platform hostname for OCI); IPv4 fallback covers
# Contabo where the platform hostname is the system UUID.
machine_id_for() {
  local machines_json="$1"
  jq -r --arg n "$NODE_NAME" --arg ip "$NODE_IPV4_VAL" '
    [
      (.[] | select((.spec.network.hostname // "") == $n) | .metadata.id),
      (.[] | select(
        ($ip != "") and (
          any(.spec.network.addresses // [] | .[]; (split("/")[0]) == $ip)
        )
      ) | .metadata.id)
    ] | .[0] // ""
  ' <<<"$machines_json"
}

deadline=$(( $(date +%s) + REGISTRATION_TIMEOUT_SECS ))
machine_id=""

while :; do
  machines_arr=$(fetch_machines)
  machine_id=$(machine_id_for "$machines_arr")
  if [[ -n "$machine_id" ]]; then
    echo "[sync-machine-label] $NODE_NAME: matched machine id=$machine_id"
    break
  fi
  if (( $(date +%s) >= deadline )); then
    echo "[sync-machine-label] WARN $NODE_NAME (ipv4=$NODE_IPV4_VAL): registration wait timed out after ${REGISTRATION_TIMEOUT_SECS}s — skipping"
    exit 0
  fi
  echo "[sync-machine-label] $NODE_NAME: not yet registered, polling again in ${REGISTRATION_POLL_SECS}s"
  sleep "$REGISTRATION_POLL_SECS"
done

# Render and apply the MachineLabels resource. Labels live in
# metadata.labels (COSI-style); MachineLabelsSpec is empty.
manifest=$(jq -n \
  --arg id "$machine_id" \
  --argjson labels "$NODE_LABELS_JSON" '{
    metadata: {
      namespace: "default",
      type:      "MachineLabels.omni.sidero.dev",
      id:        $id,
      labels:    $labels,
    },
    spec: {},
  }')
manifest_file=$(mktemp -t "machinelabels-${machine_id}.XXXXXX.json")
trap 'rm -f "$manifest_file"' EXIT
printf '%s\n' "$manifest" > "$manifest_file"

echo "[sync-machine-label] $NODE_NAME: applying $label_count label(s) to machine $machine_id"
if omnictl apply -f "$manifest_file" 2>&1 | sed 's/^/  /'; then
  echo "[sync-machine-label] $NODE_NAME: done"
  exit 0
else
  echo "[sync-machine-label] ERROR $NODE_NAME: omnictl apply MachineLabels failed" >&2
  exit 1
fi
```

- [ ] **Step 3: Make it executable**

```bash
chmod +x tofu/layers/03-talos/scripts/sync-machine-label.sh
```

- [ ] **Step 4: Syntax-check with bash**

```bash
bash -n tofu/layers/03-talos/scripts/sync-machine-label.sh && echo "OK"
```

Expected: `OK`.

- [ ] **Step 5: Sanity-check the no-op path (empty labels) without hitting Omni**

```bash
NODE_NAME=test \
NODE_LABELS_JSON='{}' \
OMNI_SERVICE_ACCOUNT_KEY=dummy \
bash tofu/layers/03-talos/scripts/sync-machine-label.sh
```

Expected: prints `[sync-machine-label] test: no labels to apply (empty map), exiting` and exits 0.

- [ ] **Step 6: Sanity-check that invalid JSON is rejected**

```bash
NODE_NAME=test \
NODE_LABELS_JSON='not-json' \
OMNI_SERVICE_ACCOUNT_KEY=dummy \
bash tofu/layers/03-talos/scripts/sync-machine-label.sh
```

Expected: prints `[sync-machine-label] test: NODE_LABELS_JSON is not valid JSON — aborting` and exits 1.

- [ ] **Step 7: Commit**

```bash
git add tofu/layers/03-talos/scripts/sync-machine-label.sh
git commit -m "03-talos: add per-machine sync-machine-label.sh (one node per invocation)"
```

---

## Task 2: Add the `label_sync_retry_token` variable

**Goal:** Operator escape-hatch to re-run all instances without changing label content.

**Files:**
- Modify: `tofu/layers/03-talos/variables.tf`

- [ ] **Step 1: Read the current variables.tf to find a sensible insertion point**

```bash
grep -n "^variable" tofu/layers/03-talos/variables.tf
```

You'll see `r2_account_id`, `cluster_name`, `age_recipients`, `ci_run_id`, `local_inventory_dir`, `omni_endpoint`, `talos_version`. Pick a slot — adjacent to `omni_endpoint` makes semantic sense.

- [ ] **Step 2: Add the variable block immediately after the `omni_endpoint` block**

Find this block in `tofu/layers/03-talos/variables.tf`:

```hcl
variable "omni_endpoint" {
  type        = string
  default     = "https://cp.stawi.org"
  description = "Omni machine-api endpoint omnictl dials for cluster-template sync and per-machine label updates. cpd.<zone> (gray-cloud, direct-to-VPS, real LE cert) is the supported path; cp.<zone> is CF-proxied and the free plan downgrades HTTP/2 to HTTP/1.1, which breaks omnictl's gRPC client."
}
```

Add this block IMMEDIATELY AFTER it (before the next existing variable):

```hcl
variable "label_sync_retry_token" {
  type        = string
  default     = ""
  description = "Operator-only escape hatch for the per-machine label sync. Included in every null_resource.omnictl_machine_label instance's triggers map — bumping the string re-keys all instances, forcing a fleet-wide re-run. Use after a polling-timeout that left a machine unlabeled when no other input has changed. Empty in steady state."
}
```

- [ ] **Step 3: Validate**

```bash
cd tofu/layers/03-talos
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add tofu/layers/03-talos/variables.tf
git commit -m "03-talos: add label_sync_retry_token variable (operator retry knob)"
```

---

## Task 3: Replace the singleton resource with `for_each`

**Goal:** `null_resource.omnictl_machine_labels` (singleton) → `null_resource.omnictl_machine_label` keyed by node name. Delete the now-unused `local_sensitive_file` and `sync_machine_labels_path` local.

**Files:**
- Modify: `tofu/layers/03-talos/cluster.tf` (lines ~40-124).

- [ ] **Step 1: Read the current cluster.tf block to know what you're replacing**

```bash
sed -n '39,125p' tofu/layers/03-talos/cluster.tf
```

Confirm the structure matches what's expected (sync_machine_labels_path local at line ~40, local_sensitive_file.node_labels_json at line ~80, null_resource.omnictl_machine_labels at line ~86 through ~124).

- [ ] **Step 2: Replace the `sync_machine_labels_path` local**

Open `tofu/layers/03-talos/cluster.tf`. Find:

```hcl
locals {
  sync_machine_labels_path = "${path.module}/scripts/sync-machine-labels.sh"

  # Per-node labels-and-ip envelope.
```

Replace just that one line (`sync_machine_labels_path = ...`) with:

```hcl
  sync_machine_label_path = "${path.module}/scripts/sync-machine-label.sh"
```

(Singular `label`, matches the new per-machine script's filename.)

- [ ] **Step 3: Delete the `local_sensitive_file.node_labels_json` resource**

In the same file, find this block (~lines 80-84):

```hcl
resource "local_sensitive_file" "node_labels_json" {
  filename        = "${path.module}/.terraform/node-labels.json"
  content         = jsonencode(local.omni_machine_apply_per_node)
  file_permission = "0600"
}
```

Delete the entire block (all 5 lines). Per-machine labels flow via env now, not a shared JSON file.

- [ ] **Step 4: Replace the singleton resource with the `for_each` form**

Find this block (~lines 86-124):

```hcl
resource "null_resource" "omnictl_machine_labels" {
  # Triggers on:
  #   labels_sha — re-run when the desired-labels content changes (e.g.
  #                operator adds a label to a node).
  #   nodes_sha  — re-run when ANY upstream node attribute changes
  #                (instance ID, ipv4, etc.). Critical for OCI's
  #                destroy+create flow: the node name is stable but
  #                Omni only sees a fresh Machine after the new
  #                instance phones home, and we need to relabel it
  #                because labels are NOT carried over by Omni
  #                between Machine identities.
  #   script_sha — re-run when the reconciler script changes. Without
  #                this, a script-side bug fix wouldn't get picked up
  #                until something else in the trigger set changed.
  #   endpoint / cluster — invalidate on env target changes.
  triggers = {
    labels_sha = sha256(local_sensitive_file.node_labels_json.content)
    nodes_sha  = sha256(jsonencode(local.all_nodes_from_state))
    script_sha = filesha256(local.sync_machine_labels_path)
    endpoint   = var.omni_endpoint
    cluster    = var.cluster_name
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      OMNI_ENDPOINT      = var.omni_endpoint
      OMNI_CLUSTER       = var.cluster_name
      NODE_LABELS_JSON   = local_sensitive_file.node_labels_json.filename
      SYNC_LABELS_SCRIPT = local.sync_machine_labels_path
    }
    command = <<-EOT
      set -euo pipefail
      command -v omnictl >/dev/null || { echo "omnictl not found in PATH; install it first." >&2; exit 1; }
      [[ -n "$${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "OMNI_SERVICE_ACCOUNT_KEY not set in env." >&2; exit 1; }
      bash "$SYNC_LABELS_SCRIPT" "$NODE_LABELS_JSON"
    EOT
  }
}
```

Replace it with:

```hcl
# Per-machine MachineLabels sync — one null_resource instance per node
# in inventory. The singleton form this replaced (re-keyed on the sha
# of the full nodes map) re-ran the reconciler against EVERY machine
# whenever ANY node attribute moved; that turned a single-account
# onboarding into a fleet-wide 15-minute polling loop.
#
# Per-instance triggers carry only that node's label content + ipv4,
# plus shared env-target shas. Adding a node creates one new instance;
# changing one node's role re-keys exactly one instance. Bug-fixing
# the script (script_sha) or rerouting Omni (endpoint/cluster) still
# fans out — those are semantics-changing events that genuinely need
# a fleet-wide replay.
#
# label_sync_retry_token (var) is the operator escape hatch for the
# polling-timeout case: a machine that wasn't yet registered when its
# instance first applied has the resource marked created with a WARN,
# and re-applying with the same inputs is a no-op. Bumping the token
# re-keys every instance and forces a fresh attempt.
resource "null_resource" "omnictl_machine_label" {
  for_each = local.omni_machine_apply_per_node

  triggers = {
    labels_sha  = sha256(jsonencode(each.value.labels))
    ipv4        = try(each.value.ipv4, "")
    script_sha  = filesha256(local.sync_machine_label_path)
    endpoint    = var.omni_endpoint
    cluster     = var.cluster_name
    retry_token = var.label_sync_retry_token
  }

  provisioner "local-exec" {
    interpreter = ["bash", "-c"]
    environment = {
      OMNI_ENDPOINT     = var.omni_endpoint
      OMNI_CLUSTER      = var.cluster_name
      NODE_NAME         = each.key
      NODE_LABELS_JSON  = jsonencode(each.value.labels)
      NODE_IPV4         = try(each.value.ipv4, "")
      SYNC_LABEL_SCRIPT = local.sync_machine_label_path
    }
    command = <<-EOT
      set -euo pipefail
      command -v omnictl >/dev/null || { echo "omnictl not found in PATH; install it first." >&2; exit 1; }
      [[ -n "$${OMNI_SERVICE_ACCOUNT_KEY:-}" ]] || { echo "OMNI_SERVICE_ACCOUNT_KEY not set in env." >&2; exit 1; }
      bash "$SYNC_LABEL_SCRIPT"
    EOT
  }
}
```

- [ ] **Step 5: Validate**

```bash
cd tofu/layers/03-talos
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

If validate fails citing `local_sensitive_file.node_labels_json` or `local.sync_machine_labels_path` (plural) references: search for stragglers:

```bash
grep -n "local_sensitive_file.node_labels_json\|sync_machine_labels_path" tofu/layers/03-talos/cluster.tf
```

Expected: no output. If any matches show up, remove them and re-validate.

- [ ] **Step 6: Commit**

```bash
git add tofu/layers/03-talos/cluster.tf
git commit -m "03-talos: per-node MachineLabels via null_resource for_each"
```

---

## Task 4: Delete the old bulk reconciler script

**Goal:** No two reconcilers in the tree. The new per-machine script is the only one.

**Files:**
- Delete: `tofu/layers/03-talos/scripts/sync-machine-labels.sh` (plural).

- [ ] **Step 1: Confirm nothing else references it**

```bash
grep -rn "sync-machine-labels.sh\|sync_machine_labels_path" tofu/ scripts/ .github/ docs/ 2>/dev/null | grep -v "docs/superpowers/"
```

Expected: zero matches. (Spec / plan docs under `docs/superpowers/` may still mention the plural name as historical context — that's fine.)

If any live code references show up, fix them before deleting the script.

- [ ] **Step 2: Delete the file**

```bash
git rm tofu/layers/03-talos/scripts/sync-machine-labels.sh
```

- [ ] **Step 3: Validate 03-talos one more time**

```bash
cd tofu/layers/03-talos
tofu init -backend=false
tofu validate
cd -
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Commit**

```bash
git add -A tofu/layers/03-talos/scripts/
git commit -m "03-talos: delete bulk sync-machine-labels.sh (superseded by per-machine script)"
```

---

## Task 5: Push branch + open PR + verify CI plan output

**Goal:** Confirm the migration apply will be `1 to destroy, N to add` and nothing else.

- [ ] **Step 1: Push branch**

```bash
git push -u origin narrow-label-sync
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "narrow 03-talos label sync to per-machine null_resource" --body "$(cat <<'EOF'
## Summary
Replaces the singleton `null_resource.omnictl_machine_labels` with `null_resource.omnictl_machine_label["<node>"]` keyed per-node. Adding a node creates one resource; changing a node's role re-keys one; steady state is zero diff.

Spec: `docs/superpowers/specs/2026-05-20-narrow-label-sync-design.md`
Plan: `docs/superpowers/plans/2026-05-20-narrow-label-sync-plan.md`

## Changes
- New `tofu/layers/03-talos/scripts/sync-machine-label.sh` — per-machine reconciler (reads `NODE_NAME` / `NODE_LABELS_JSON` / `NODE_IPV4` from env, polls Omni for that one machine, applies MachineLabels).
- `tofu/layers/03-talos/cluster.tf` — `null_resource.omnictl_machine_label` with `for_each = local.omni_machine_apply_per_node`. Drops `local_sensitive_file.node_labels_json` and `sync_machine_labels_path` local.
- `tofu/layers/03-talos/variables.tf` — new `label_sync_retry_token` variable (operator escape hatch).
- `tofu/layers/03-talos/scripts/sync-machine-labels.sh` (plural) deleted.

## Test plan
- [ ] CI green: `tofu-plan` succeeds for 03-talos.
- [ ] 03-talos plan shape: `1 to destroy, N to add` where N = current node count. The destroy is the old singleton, the adds are the per-machine instances.
- [ ] After merge: `tofu-apply` succeeds for 03-talos. All N instances complete with `applied=1` (each) and no `errored`.
- [ ] Subsequent `tofu-plan` (re-run on main) shows zero diff for 03-talos.
- [ ] Behaviour test: bump `node.antinvestor.io/role` on one node in inventory; next plan shows exactly one instance changing.
EOF
)"
```

- [ ] **Step 3: Wait for CI and inspect the 03-talos plan**

```bash
gh pr checks
```

Wait until `tofu-plan` is success/failure. Then:

```bash
PLAN_RUN=$(gh run list --workflow=tofu-plan --branch narrow-label-sync --limit 1 --json databaseId -q '.[0].databaseId')
TALOS_JOB=$(gh run view "$PLAN_RUN" --json jobs -q '.jobs[] | select(.name=="talos / run") | .databaseId')
curl -s -H "Authorization: token $(gh auth token)" -L "https://api.github.com/repos/stawi-org/deployment.infra/actions/jobs/$TALOS_JOB/logs" -o /tmp/talos-plan.log
grep -E "Plan:|will be created|will be destroyed" /tmp/talos-plan.log | head -20
```

Expected output:
```
Plan: N to add, 0 to change, 1 to destroy.
  # null_resource.omnictl_machine_labels will be destroyed
  # null_resource.omnictl_machine_label["contabo-bwire-node-1"] will be created
  # null_resource.omnictl_machine_label["contabo-bwire-node-2"] will be created
  # null_resource.omnictl_machine_label["oci-allanofwiti-node-1"] will be created
  # null_resource.omnictl_machine_label["oci-alimbacho67-node-1"] will be created
  # null_resource.omnictl_machine_label["oci-anto-node-1"] will be created
  # null_resource.omnictl_machine_label["oci-brianelvis33-node-1"] will be created
  # null_resource.omnictl_machine_label["oci-bwire-node-1"] will be created
```

(Plus the per-apply `local_sensitive_file.node_labels_json will be destroyed` line — that's the now-removed shared JSON file.)

If anything ELSE shows up as changed (`Plan: M to add` where M ≠ N+1, or `will be replaced` on unrelated resources), pause and investigate — the migration should be scoped to exactly this.

- [ ] **Step 4: Merge the PR**

```bash
gh pr merge --squash
```

- [ ] **Step 5: Trigger and watch the apply**

```bash
gh workflow run tofu-layer.yml -f layer=03-talos -f mode=apply -f environment=production
sleep 5
APPLY_RUN=$(gh run list --workflow=tofu-layer.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$APPLY_RUN" --exit-status
```

Apply takes ~3-5 minutes (parallel per-machine, each polls only its own machine then applies one MachineLabels resource).

Expected last line: `Apply complete! Resources: N added, 0 changed, 1 destroyed.`

- [ ] **Step 6: Run a no-op plan to confirm steady state**

```bash
gh workflow run tofu-layer.yml -f layer=03-talos -f mode=plan
sleep 5
PLAN_RUN=$(gh run list --workflow=tofu-layer.yml --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$PLAN_RUN" --exit-status
TALOS_JOB=$(gh run view "$PLAN_RUN" --json jobs -q '.jobs[0].databaseId')
curl -s -H "Authorization: token $(gh auth token)" -L "https://api.github.com/repos/stawi-org/deployment.infra/actions/jobs/$TALOS_JOB/logs" -o /tmp/talos-plan.log
grep -E "Plan:|No changes" /tmp/talos-plan.log | head -5
```

Expected: `No changes. Your infrastructure matches the configuration.` OR `Plan: 1 to add, 0 to change, 0 to destroy.` (the always-rendered `local_sensitive_file.node_labels_json` sentinel was deleted, so that 1-to-add should also be gone — clean zero-diff).

If the plan shows any `null_resource.omnictl_machine_label` resources changing, something is wrong with the trigger shape — investigate.

---

## Self-review checklist

After completing all tasks, verify against `docs/superpowers/specs/2026-05-20-narrow-label-sync-design.md`:

- [ ] **Spec coverage:**
  - Architecture: per-machine `for_each` (Task 3) ✓
  - Triggers: labels_sha + ipv4 + script_sha + endpoint + cluster + retry_token (Task 3) ✓
  - Per-machine script reading env (Task 1) ✓
  - `local_sensitive_file` removed (Task 3) ✓
  - Bulk script deleted (Task 4) ✓
  - `label_sync_retry_token` variable (Task 2) ✓
  - Migration path A: destroy + recreate via single apply (Task 5, Step 5) ✓
  - Timeout exits 0 with WARN (Task 1, Step 2 implementation) ✓
  - `omnictl apply` failure exits non-zero so tofu marks the one instance failed (Task 1, Step 2) ✓
- [ ] **No placeholders:** No "TBD", "TODO", or "implement later" outside of intentional spec references.
- [ ] **Type consistency:** `local.omni_machine_apply_per_node` shape (`{labels = {...}, ipv4 = "..."}`) is consistent across cluster.tf for_each binding (Task 3) and what the script reads via `NODE_LABELS_JSON` / `NODE_IPV4` (Task 1). Resource name singular `omnictl_machine_label` everywhere post-rename.
- [ ] **Tests:** Each task ends with `tofu validate` (the closest tofu primitive to "unit test"). Task 1 includes two bash-level sanity checks (no-op and invalid-JSON paths). Task 5 has the live migration-apply + no-op-replan verification.
