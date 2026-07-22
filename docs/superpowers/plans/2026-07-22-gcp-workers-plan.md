# GCP GCE Spot workers — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add GCP as a full peer provider that provisions **two Spot/preemptible Talos workers per project**, with WIF auth, bootstrap PR onboarding, OpenTofu layer, Omni-aware image import, and cluster-provision integration.

**Architecture:** Mirror the OCI multi-account model: `accounts.yaml` + SOPS `auth.yaml` in-repo, R2 `nodes.yaml` for desired/observed inventory, per-account state for `02-gcp-infra`, CI matrix cells with GitHub OIDC → GCP WIF. Empty accounts seed exactly two Spot `e2-medium` workers. Omni MachineClass `workers` already matches `node.stawi.org/role=worker`.

**Tech Stack:** OpenTofu, hashicorp/google provider, GitHub Actions OIDC + GCP Workload Identity Federation, omnictl (Omni-aware images), Cloudflare R2 inventory, SOPS/age, Python (seed scripts), bash (bootstrap).

**Reference spec:** [`docs/superpowers/specs/2026-07-22-gcp-workers-design.md`](../specs/2026-07-22-gcp-workers-design.md)

---

## Pre-flight

- Work on branch `feat/gcp-workers` (create from `main` or continue from `docs/gcp-workers-design` after merge/rebase).
- Pre-commit active: do **not** use `--no-verify`. Fix hook failures in a follow-up commit if needed.
- Do not add real GCP projects or secrets in v1 PRs until Task 12 live onboard; ship with `gcp: []` until a real bootstrap PR lands.
- Default pack (locked): **2 × Spot `e2-medium`, 50 GB boot, zone `<region>-b`, names `gcp-<account>-node-{1,2}`**.

---

## File map

| Path | Responsibility |
|---|---|
| `tofu/shared/accounts.yaml` | Add `gcp: []` roster key |
| `tofu/shared/accounts/gcp/<acct>/auth.yaml` | SOPS WIF auth (created by bootstrap, not hand-committed empty) |
| `tofu/shared/patches/node-gcp.tftpl` | Per-node Talos labels/annotations + public-ip overwrite |
| `tofu/modules/node-gcp/*` | Single GCE instance + node contract |
| `tofu/modules/gcp-account-infra/*` | VPC, firewall, image check, node for_each |
| `tofu/layers/02-gcp-infra/*` | Per-account layer wiring + nodes writer |
| `scripts/lib/gcp_default_pack.py` | Default pack + validation helpers |
| `scripts/lib/test_gcp_default_pack.py` | Unit tests for seed policy |
| `scripts/ensure-gcp-default-capacity.py` | Seed empty R2 inventories |
| `scripts/stage-gcp-auth-from-repo.sh` | Decrypt repo auth for CI |
| `scripts/bootstrap-gcp-wif.sh` | Idempotent WIF + PR |
| `.github/workflows/onboard-gcp.yml` | Post-merge seed + cluster-provision |
| `.github/workflows/sync-talos-images.yml` | GCP image download + import |
| `.github/workflows/tofu-layer.yml` | Layer auth + backend key for `02-gcp-infra` |
| `.github/workflows/tofu-plan.yml` / `tofu-apply.yml` | Matrix over `gcp:` |
| `.github/workflows/cluster-provision.yml` | Wire GCP into full path |
| `scripts/sync-sops-check.sh` | Include `02-gcp-infra` |
| `docs/topology.md`, `README.md`, `scripts/README.md`, `docs/config/gcp/` | Operator docs |

---

### Task 1: Branch + accounts roster key

**Files:**
- Modify: `tofu/shared/accounts.yaml`
- Modify: `docs/superpowers/specs/2026-07-22-gcp-workers-design.md` (already updated for Spot×2 — keep in branch)

- [ ] **Step 1: Create feature branch from latest main**

```bash
git fetch origin main
git checkout -b feat/gcp-workers origin/main
# if design commits exist only on docs/gcp-workers-design, cherry-pick them:
# git cherry-pick 8e0da18..<design-tip>
```

- [ ] **Step 2: Add empty `gcp` list to accounts.yaml**

Append to `tofu/shared/accounts.yaml`:

```yaml
gcp: []
```

Full file should look like:

```yaml
# Declares which provider/account keys exist. The node-state module uses
# these to know which R2 keys to read. Edit this file to onboard a new
# account; the inventory tree is seeded separately by seed-inventory.sh.
contabo:
  - bwire
oracle:
  - bwire
  # ... existing oracle accounts ...
onprem:
  - tindase
gcp: []
```

- [ ] **Step 3: Commit**

```bash
git add tofu/shared/accounts.yaml docs/superpowers/specs/2026-07-22-gcp-workers-design.md
git commit -m "feat(gcp): add empty gcp roster key and Spot×2 design"
```

---

### Task 2: Default pack library + tests (TDD)

**Files:**
- Create: `scripts/lib/gcp_default_pack.py`
- Create: `scripts/lib/test_gcp_default_pack.py`

- [ ] **Step 1: Write failing tests**

```python
# scripts/lib/test_gcp_default_pack.py
import unittest

from gcp_default_pack import (
    DEFAULT_BOOT_DISK_GB,
    DEFAULT_MACHINE_TYPE,
    default_nodes,
    validate_nodes,
)


class TestGcpDefaultPack(unittest.TestCase):
    def test_default_nodes_count_and_names(self):
        nodes = default_nodes("stawi-prod", region="europe-west1")
        self.assertEqual(len(nodes), 2)
        self.assertIn("gcp-stawi-prod-node-1", nodes)
        self.assertIn("gcp-stawi-prod-node-2", nodes)

    def test_default_nodes_are_spot_workers(self):
        nodes = default_nodes("acme", region="us-central1")
        for name, n in nodes.items():
            self.assertEqual(n["role"], "worker")
            self.assertTrue(n["preemptible"])
            self.assertEqual(n["machine_type"], DEFAULT_MACHINE_TYPE)
            self.assertEqual(n["boot_disk_gb"], DEFAULT_BOOT_DISK_GB)
            self.assertEqual(n["zone"], "us-central1-b")

    def test_validate_rejects_controlplane(self):
        with self.assertRaises(ValueError):
            validate_nodes(
                {
                    "gcp-x-node-1": {
                        "role": "controlplane",
                        "machine_type": "e2-medium",
                        "zone": "europe-west1-b",
                        "boot_disk_gb": 50,
                        "preemptible": True,
                    }
                }
            )

    def test_validate_accepts_two_spot_workers(self):
        validate_nodes(default_nodes("x", region="europe-west1"))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests — expect fail (module missing)**

```bash
cd scripts/lib && python3 -m unittest test_gcp_default_pack -v
```

Expected: `ModuleNotFoundError` or import error.

- [ ] **Step 3: Implement library**

```python
# scripts/lib/gcp_default_pack.py
"""Default GCP inventory pack: two Spot workers per account."""

from __future__ import annotations

from typing import Any

DEFAULT_MACHINE_TYPE = "e2-medium"
DEFAULT_BOOT_DISK_GB = 50
DEFAULT_NODE_COUNT = 2


def default_zone(region: str) -> str:
    region = (region or "").strip()
    if not region:
        raise ValueError("region is required")
    return f"{region}-b"


def default_worker(account: str, index: int, *, region: str) -> dict[str, Any]:
    if index < 1:
        raise ValueError("index must be >= 1")
    return {
        "role": "worker",
        "machine_type": DEFAULT_MACHINE_TYPE,
        "zone": default_zone(region),
        "boot_disk_gb": DEFAULT_BOOT_DISK_GB,
        "preemptible": True,
        "labels": {
            "node.stawi.org/plane": "worker",
            "node.stawi.org/capacity-class": "spot",
        },
        "annotations": {
            "node.stawi.org/operator-note": (
                f"default Spot pack {DEFAULT_MACHINE_TYPE}/{DEFAULT_BOOT_DISK_GB}GB"
            ),
        },
    }


def default_nodes(account: str, *, region: str) -> dict[str, dict[str, Any]]:
    """Return node map keyed by canonical names gcp-<account>-node-N."""
    acct = account.strip()
    if not acct:
        raise ValueError("account is required")
    return {
        f"gcp-{acct}-node-{i}": default_worker(acct, i, region=region)
        for i in range(1, DEFAULT_NODE_COUNT + 1)
    }


def validate_nodes(nodes: dict[str, Any]) -> None:
    if not isinstance(nodes, dict):
        raise ValueError("nodes must be a mapping")
    for name, n in nodes.items():
        if not isinstance(n, dict):
            raise ValueError(f"{name}: node must be a mapping")
        role = n.get("role")
        if role != "worker":
            raise ValueError(f"{name}: role must be 'worker' (got {role!r})")
        for req in ("machine_type", "zone", "boot_disk_gb"):
            if req not in n:
                raise ValueError(f"{name}: missing required field {req}")
        boot = n["boot_disk_gb"]
        if not isinstance(boot, int) or boot < 50:
            raise ValueError(f"{name}: boot_disk_gb must be int >= 50")
```

- [ ] **Step 4: Run tests — expect pass**

```bash
cd scripts/lib && python3 -m unittest test_gcp_default_pack -v
```

Expected: `OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/gcp_default_pack.py scripts/lib/test_gcp_default_pack.py
git commit -m "feat(gcp): default Spot pack library (2 workers) with tests"
```

---

### Task 3: Ensure-default-capacity script + tests

**Files:**
- Create: `scripts/ensure-gcp-default-capacity.py`
- Create: `scripts/lib/test_ensure_gcp_default_capacity.py` (or extend unit tests via subprocess / import)

- [ ] **Step 1: Implement ensure script**

```python
#!/usr/bin/env python3
"""Seed empty GCP account inventories with the default two Spot workers.

Usage:
  python3 scripts/ensure-gcp-default-capacity.py \\
    --inventory-dir /tmp/inventory/gcp \\
    --accounts-yaml tofu/shared/accounts.yaml \\
    --auth-dir /tmp/gcp-auth-from-repo \\
    --write
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from gcp_default_pack import default_nodes, validate_nodes  # noqa: E402


def _load_accounts(path: Path) -> list[str]:
    doc = yaml.safe_load(path.read_text()) or {}
    return list(doc.get("gcp") or [])


def _region_for_account(auth_dir: Path | None, account: str) -> str:
    if auth_dir is None:
        return "europe-west1"
    auth_path = auth_dir / account / "auth.yaml"
    if not auth_path.is_file():
        return "europe-west1"
    doc = yaml.safe_load(auth_path.read_text()) or {}
    auth = doc.get("auth") or doc
    return str(auth.get("region") or "europe-west1")


def ensure_account(
    account: str,
    path: Path,
    *,
    region: str,
    write: bool,
) -> tuple[str, bool]:
    if path.is_file():
        doc = yaml.safe_load(path.read_text()) or {}
    else:
        doc = {
            "labels": {"node.stawi.org/account": account},
            "annotations": {"node.stawi.org/account-owner": "platform"},
            "nodes": {},
        }

    nodes = doc.get("nodes") or {}
    if nodes:
        try:
            validate_nodes(nodes)
        except ValueError as e:
            return (f"{account}: ERROR {e}", False)
        return (f"{account}: unchanged ({len(nodes)} nodes)", False)

    nodes = default_nodes(account, region=region)
    doc["nodes"] = nodes
    doc.setdefault("labels", {"node.stawi.org/account": account})
    doc.setdefault("annotations", {"node.stawi.org/account-owner": "platform"})
    if write:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(doc, sort_keys=False))
    return (
        f"{account}: seeded {', '.join(sorted(nodes))} as Spot "
        f"{list(nodes.values())[0]['machine_type']}",
        True,
    )


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--inventory-dir", type=Path, required=True)
    p.add_argument("--accounts-yaml", type=Path, required=True)
    p.add_argument("--auth-dir", type=Path, default=None)
    p.add_argument("--write", action="store_true")
    args = p.parse_args()

    accounts = _load_accounts(args.accounts_yaml)
    if not accounts:
        print("no gcp accounts in accounts.yaml — nothing to do")
        return 0

    changed_any = False
    for acct in accounts:
        region = _region_for_account(args.auth_dir, acct)
        path = args.inventory_dir / acct / "nodes.yaml"
        line, changed = ensure_account(acct, path, region=region, write=args.write)
        print(line)
        changed_any = changed_any or changed
        if line.startswith(f"{acct}: ERROR"):
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
```

- [ ] **Step 2: Manual dry-run test**

```bash
mkdir -p /tmp/gcp-seed-test
python3 scripts/ensure-gcp-default-capacity.py \
  --inventory-dir /tmp/gcp-seed-test \
  --accounts-yaml <(printf 'gcp:\n  - demo\n') \
  --write
python3 -c "import yaml; d=yaml.safe_load(open('/tmp/gcp-seed-test/demo/nodes.yaml')); assert len(d['nodes'])==2; assert all(n['preemptible'] for n in d['nodes'].values())"
# second run must be no-op
python3 scripts/ensure-gcp-default-capacity.py \
  --inventory-dir /tmp/gcp-seed-test \
  --accounts-yaml <(printf 'gcp:\n  - demo\n') \
  --write | tee /tmp/seed2.out
grep -q unchanged /tmp/seed2.out
```

Expected: first run seeds two nodes; second prints `unchanged (2 nodes)`.

- [ ] **Step 3: Commit**

```bash
git add scripts/ensure-gcp-default-capacity.py
git commit -m "feat(gcp): ensure-gcp-default-capacity seeds two Spot workers"
```

---

### Task 4: stage-gcp-auth-from-repo.sh

**Files:**
- Create: `scripts/stage-gcp-auth-from-repo.sh` (mode `0755`)

- [ ] **Step 1: Write script** (mirror oracle staging)

```bash
#!/usr/bin/env bash
# Decrypt repo-resident gcp auth.yaml files into:
#   <out>/<account>/auth.yaml  (plaintext)
#
# Usage: scripts/stage-gcp-auth-from-repo.sh [OUT_DIR] [REPO_ROOT]
set -euo pipefail

OUT="${1:-/tmp/gcp-auth-from-repo}"
ROOT="${2:-.}"
ROOT="$(cd "$ROOT" && pwd)"

command -v sops >/dev/null 2>&1 || { echo "missing: sops" >&2; exit 2; }

rm -rf "$OUT"
mkdir -p "$OUT"

shopt -s nullglob
count=0
for f in "$ROOT"/tofu/shared/accounts/gcp/*/auth.yaml; do
  acct=$(basename "$(dirname "$f")")
  mkdir -p "$OUT/$acct"
  if ! sops -d --input-type yaml --output-type yaml "$f" > "$OUT/$acct/auth.yaml"; then
    echo "::error::failed to decrypt $f" >&2
    exit 1
  fi
  count=$((count + 1))
done

echo "::notice::staged ${count} gcp auth.yaml file(s) from repo into ${OUT}" >&2
printf '%s\n' "$OUT"
```

- [ ] **Step 2: chmod + commit**

```bash
chmod +x scripts/stage-gcp-auth-from-repo.sh
git add scripts/stage-gcp-auth-from-repo.sh
git commit -m "feat(gcp): stage-gcp-auth-from-repo for CI WIF"
```

---

### Task 5: node-gcp module

**Files:**
- Create: `tofu/modules/node-gcp/versions.tf`
- Create: `tofu/modules/node-gcp/variables.tf`
- Create: `tofu/modules/node-gcp/main.tf`
- Create: `tofu/modules/node-gcp/outputs.tf`

- [ ] **Step 1: versions.tf**

```hcl
terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}
```

- [ ] **Step 2: variables.tf**

```hcl
variable "name" {
  type        = string
  description = "Canonical node name, e.g. gcp-stawi-prod-node-1"
}

variable "role" {
  type = string
  validation {
    condition     = var.role == "worker"
    error_message = "GCP nodes must have role 'worker' in v1."
  }
}

variable "machine_type" { type = string }
variable "zone" { type = string }
variable "boot_disk_gb" {
  type = number
  validation {
    condition     = var.boot_disk_gb >= 50
    error_message = "boot_disk_gb must be >= 50 (Talos image floor)."
  }
}
variable "preemptible" {
  type        = bool
  default     = true
  description = "When true, use GCE Spot (provisioning_model=SPOT)."
}
variable "image" {
  type        = string
  description = "GCE image self_link or family path."
}
variable "network" { type = string }
variable "subnetwork" { type = string }
variable "account_key" { type = string }
variable "region" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}
variable "annotations" {
  type    = map(string)
  default = {}
}
variable "force_reinstall_generation" {
  type    = number
  default = 1
  validation {
    condition     = var.force_reinstall_generation >= 1
    error_message = "force_reinstall_generation must be >= 1."
  }
}
```

- [ ] **Step 3: main.tf**

```hcl
resource "terraform_data" "force_reinstall" {
  input = var.force_reinstall_generation
}

resource "google_compute_instance" "this" {
  name         = var.name
  machine_type = var.machine_type
  zone         = var.zone

  boot_disk {
    initialize_params {
      image = var.image
      size  = var.boot_disk_gb
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = var.network
    subnetwork = var.subnetwork
    access_config {} # ephemeral public IPv4
  }

  can_ip_forward = true

  # Spot by default; standard VM when preemptible=false.
  dynamic "scheduling" {
    for_each = var.preemptible ? [1] : [0]
    content {
      preemptible                 = var.preemptible
      automatic_restart           = var.preemptible ? false : true
      on_host_maintenance         = var.preemptible ? "TERMINATE" : "MIGRATE"
      provisioning_model          = var.preemptible ? "SPOT" : "STANDARD"
      instance_termination_action = var.preemptible ? "DELETE" : null
    }
  }

  # Talos boots maintenance mode; Omni image carries siderolink.api.
  metadata = {
    # Empty user-data / startup-script intentionally.
  }

  labels = {
    stawi_provider = "gcp"
    stawi_account  = replace(var.account_key, "/[^a-z0-9_\\-]/", "-")
    stawi_role     = var.role
    stawi_spot     = var.preemptible ? "true" : "false"
  }

  lifecycle {
    ignore_changes = [
      metadata,
    ]
    replace_triggered_by = [
      terraform_data.force_reinstall,
    ]
  }
}

locals {
  nic0        = google_compute_instance.this.network_interface[0]
  private_ip  = try(local.nic0.network_ip, null)
  public_ip   = try(local.nic0.access_config[0].nat_ip, null)
  ipv4        = coalesce(local.public_ip, local.private_ip)
  derived_labels = merge(
    {
      "node.stawi.org/provider" = "gcp"
      "node.stawi.org/account"  = var.account_key
      "node.stawi.org/role"     = var.role
      "node.stawi.org/name"     = var.name
      "node.stawi.org/spot"     = var.preemptible ? "true" : "false"
    },
    var.labels,
  )
  derived_annotations = merge(
    {
      "node.stawi.org/provider"     = "gcp"
      "node.stawi.org/account"      = var.account_key
      "node.stawi.org/role"         = var.role
      "node.stawi.org/machine-type" = var.machine_type
      "node.stawi.org/zone"         = var.zone
    },
    # Flannel public-ip overwrite when external IP is present
    local.public_ip != null ? {
      "flannel.alpha.coreos.com/public-ip-overwrite" = local.public_ip
    } : {},
    var.annotations,
  )
}
```

Note: if OpenTofu rejects `dynamic "scheduling"` with both branches, use two separate resource configurations or a single block with ternary fields — implementers should pick the form that `tofu validate` accepts for the pinned google provider.

- [ ] **Step 4: outputs.tf**

```hcl
output "node" {
  description = "Node contract for layer 03."
  value = {
    name                   = var.name
    role                   = var.role
    provider               = "gcp"
    ipv4                   = local.ipv4
    ipv6                   = null
    public_ipv4            = local.public_ip
    private_ipv4           = local.private_ip
    talos_endpoint         = local.ipv4
    kubespan_endpoint      = local.ipv4
    derived_labels         = local.derived_labels
    derived_annotations    = local.derived_annotations
    instance_id            = google_compute_instance.this.id
    bastion_id             = null
    account_key            = var.account_key
    config_apply_source    = "ci"
    image_apply_generation = google_compute_instance.this.instance_id
  }
}

output "id" { value = google_compute_instance.this.id }
output "self_link" { value = google_compute_instance.this.self_link }
output "machine_type" { value = var.machine_type }
output "zone" { value = var.zone }
output "region" { value = var.region }
output "preemptible" { value = var.preemptible }
output "ipv4" { value = local.ipv4 }
output "public_ipv4" { value = local.public_ip }
output "private_ipv4" { value = local.private_ip }
```

- [ ] **Step 5: Commit**

```bash
git add tofu/modules/node-gcp
git commit -m "feat(gcp): node-gcp module with Spot scheduling"
```

---

### Task 6: gcp-account-infra module

**Files:**
- Create: `tofu/modules/gcp-account-infra/versions.tf`
- Create: `tofu/modules/gcp-account-infra/variables.tf`
- Create: `tofu/modules/gcp-account-infra/network.tf`
- Create: `tofu/modules/gcp-account-infra/image.tf`
- Create: `tofu/modules/gcp-account-infra/nodes.tf`
- Create: `tofu/modules/gcp-account-infra/outputs.tf`

- [ ] **Step 1: variables.tf (core)**

```hcl
variable "account_key" { type = string }
variable "project_id" { type = string }
variable "region" { type = string }
variable "vpc_cidr" {
  type    = string
  default = "10.210.0.0/16"
}
variable "nodes" {
  type = map(object({
    role          = string
    machine_type  = string
    zone          = string
    boot_disk_gb  = number
    preemptible   = optional(bool, true)
    labels        = optional(map(string), {})
    annotations   = optional(map(string), {})
  }))
  default = {}
}
variable "labels" {
  type    = map(string)
  default = {}
}
variable "annotations" {
  type    = map(string)
  default = {}
}
variable "local_inventory_dir" {
  type    = string
  default = "/tmp/inventory"
}
variable "force_reinstall_generation" {
  type    = number
  default = 1
}
```

- [ ] **Step 2: network.tf**

```hcl
resource "google_compute_network" "this" {
  name                    = "stawi-${var.account_key}"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "workers" {
  name          = "stawi-${var.account_key}-workers"
  ip_cidr_range = var.vpc_cidr
  region        = var.region
  network       = google_compute_network.this.id
}

resource "google_compute_firewall" "egress_all" {
  name      = "stawi-${var.account_key}-egress"
  network   = google_compute_network.this.name
  direction = "EGRESS"
  allow { protocol = "all" }
  destination_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "kubespan" {
  name    = "stawi-${var.account_key}-kubespan"
  network = google_compute_network.this.name
  allow {
    protocol = "udp"
    ports    = ["51820"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["stawi-talos"]
}

resource "google_compute_firewall" "talos_api" {
  name    = "stawi-${var.account_key}-talos-api"
  network = google_compute_network.this.name
  allow {
    protocol = "tcp"
    ports    = ["50000"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["stawi-talos"]
  description   = "Talos API; auth is client cert. Mirrors OCI public workers."
}
```

- [ ] **Step 3: image.tf**

```hcl
locals {
  talos_images = fileexists("${var.local_inventory_dir}/talos-images.yaml") ? yamldecode(
    file("${var.local_inventory_dir}/talos-images.yaml")
  ) : {}
  image_self_link = try(
    local.talos_images.formats.gcp.accounts[var.account_key].self_link,
    null,
  )
}

check "talos_image_present_when_nodes_exist" {
  assert {
    condition     = length(var.nodes) == 0 || local.image_self_link != null
    error_message = <<-EOT
      account ${var.account_key}: nodes declared but no GCE image self_link in
      production/inventory/talos-images.yaml (formats.gcp.accounts.${var.account_key}.self_link).
      Run sync-talos-images / cluster-provision mode=images for this project first.
    EOT
  }
}
```

- [ ] **Step 4: nodes.tf**

```hcl
module "node" {
  for_each = var.nodes
  source   = "../node-gcp"

  name                       = each.key
  role                       = each.value.role
  machine_type               = each.value.machine_type
  zone                       = each.value.zone
  boot_disk_gb               = each.value.boot_disk_gb
  preemptible                = try(each.value.preemptible, true)
  image                      = local.image_self_link
  network                    = google_compute_network.this.self_link
  subnetwork                 = google_compute_subnetwork.workers.self_link
  account_key                = var.account_key
  region                     = var.region
  labels                     = merge(var.labels, try(each.value.labels, {}))
  annotations                = merge(var.annotations, try(each.value.annotations, {}))
  force_reinstall_generation = var.force_reinstall_generation
}

# Attach network tags for firewall targeting — set on the instance module
# if not already: implementers should add tags = ["stawi-talos"] on
# google_compute_instance in node-gcp (required for firewall match).
```

Also add to `node-gcp` instance resource:

```hcl
tags = ["stawi-talos"]
```

- [ ] **Step 5: outputs.tf**

```hcl
output "nodes" {
  value = { for k, m in module.node : k => m.node }
}

output "nodes_state" {
  value = {
    for k, n in module.node : k => {
      id          = n.id
      self_link   = n.self_link
      machine_type = n.machine_type
      zone        = n.zone
      region      = n.region
      preemptible = n.preemptible
      ipv4        = n.ipv4
      public_ipv4 = n.public_ipv4
      private_ipv4 = n.private_ipv4
    }
  }
}

output "network_id" { value = google_compute_network.this.id }
```

- [ ] **Step 6: Commit**

```bash
git add tofu/modules/gcp-account-infra tofu/modules/node-gcp/main.tf
git commit -m "feat(gcp): gcp-account-infra (VPC, firewall, nodes)"
```

---

### Task 7: Layer `02-gcp-infra`

**Files:**
- Create: `tofu/layers/02-gcp-infra/backend.tf` (copy partial S3 backend from oracle)
- Create: `tofu/layers/02-gcp-infra/versions.tf`
- Create: `tofu/layers/02-gcp-infra/versions.auto.tfvars.json` (symlink or copy from shared if used)
- Create: `tofu/layers/02-gcp-infra/variables.tf`
- Create: `tofu/layers/02-gcp-infra/terraform.tfvars`
- Create: `tofu/layers/02-gcp-infra/provider-aws.tf` (copy from oracle)
- Create: `tofu/layers/02-gcp-infra/main.tf`
- Create: `tofu/layers/02-gcp-infra/nodes-writer.tf`
- Create: `tofu/layers/02-gcp-infra/outputs.tf`
- Modify: `scripts/sync-sops-check.sh` — add layer path
- Run: `scripts/sync-sops-check.sh` to generate `sops-check.tf`

- [ ] **Step 1: versions.tf**

```hcl
terraform {
  required_version = ">= 1.10"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}
```

- [ ] **Step 2: variables.tf**

```hcl
variable "r2_account_id" {
  type      = string
  sensitive = true
}

variable "account_key" {
  type = string
  validation {
    condition = contains(
      try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).gcp, []),
      var.account_key,
    )
    error_message = "account_key must be listed under gcp: in accounts.yaml."
  }
}

variable "local_inventory_dir" {
  type    = string
  default = "/tmp/inventory"
}

variable "force_reinstall_generation" {
  type    = number
  default = 1
}

variable "age_recipients" {
  type = string
}
```

- [ ] **Step 3: main.tf**

```hcl
locals {
  accounts_manifest = yamldecode(file("${path.module}/../../shared/accounts.yaml"))
  gcp_account_keys  = [var.account_key]
}

module "gcp_account_state" {
  for_each            = toset(local.gcp_account_keys)
  source              = "../../modules/node-state"
  provider_name       = "gcp"
  account             = each.key
  local_inventory_dir = var.local_inventory_dir
}

locals {
  gcp_auth_from_module = {
    for k, mod in module.gcp_account_state : k => try(mod.auth.auth, null)
  }
  gcp_nodes_from_module = {
    for k, mod in module.gcp_account_state : k => try(mod.nodes.nodes, {})
  }
  gcp_accounts_effective = {
    for k in local.gcp_account_keys : k => merge(
      try(local.gcp_auth_from_module[k], {}),
      {
        nodes       = local.gcp_nodes_from_module[k]
        labels      = try(module.gcp_account_state[k].nodes.labels, {})
        annotations = try(module.gcp_account_state[k].nodes.annotations, {})
      },
    )
  }
}

provider "google" {
  project = try(local.gcp_auth_from_module[var.account_key].project_id, null)
  region  = try(local.gcp_auth_from_module[var.account_key].region, null)
  # Credentials via GOOGLE_APPLICATION_CREDENTIALS / WIF ADC from CI.
}

module "gcp_account" {
  for_each = local.gcp_accounts_effective
  source   = "../../modules/gcp-account-infra"

  account_key                = each.key
  project_id                 = try(each.value.project_id, "")
  region                     = try(each.value.region, "")
  vpc_cidr                   = try(each.value.vpc_cidr, "10.210.0.0/16")
  nodes                      = try(each.value.nodes, {})
  labels                     = try(each.value.labels, {})
  annotations                = try(each.value.annotations, {})
  local_inventory_dir        = var.local_inventory_dir
  force_reinstall_generation = var.force_reinstall_generation
}
```

- [ ] **Step 4: nodes-writer.tf**

```hcl
module "gcp_nodes_writer" {
  for_each            = toset(local.gcp_account_keys)
  source              = "../../modules/node-state"
  local_inventory_dir = var.local_inventory_dir
  provider_name       = "gcp"
  account             = each.key

  write_nodes = true
  nodes_content = merge(
    try(module.gcp_account_state[each.key].nodes, {}),
    {
      nodes = try({
        for node_key, node in module.gcp_account[each.key].nodes_state :
        node_key => merge(
          try(module.gcp_account_state[each.key].nodes.nodes[node_key], {}),
          {
            provider_data = merge(
              try(module.gcp_account_state[each.key].nodes.nodes[node_key].provider_data, {}),
              {
                gce_instance_id        = node.id
                gce_self_link          = node.self_link
                machine_type           = node.machine_type
                zone                   = node.zone
                region                 = node.region
                preemptible            = node.preemptible
                ipv4                   = node.ipv4
                public_ipv4            = node.public_ipv4
                private_ipv4           = node.private_ipv4
                image_apply_generation = try(module.gcp_account[each.key].nodes[node_key].image_apply_generation, node.id)
                status                 = "running"
                discovered_at          = timestamp()
              },
            )
          },
        )
      }, {})
    },
  )

  depends_on = [module.gcp_account]
}
```

- [ ] **Step 5: outputs.tf**

```hcl
output "nodes" {
  description = "GCP node contracts for this account cell."
  value = merge([
    for k, m in module.gcp_account : tomap(m.nodes)
  ]...)
}
```

- [ ] **Step 6: terraform.tfvars**

```hcl
age_recipients             = "age1s570flcma83aa5lxzfvgz0y6gh5r3pnfmhlhlxamyux24dsquq7s6zffpt"
force_reinstall_generation = 1
```

- [ ] **Step 7: Register sops-check**

Add `tofu/layers/02-gcp-infra` to `LAYERS` in `scripts/sync-sops-check.sh`, then:

```bash
./scripts/sync-sops-check.sh
ls tofu/layers/02-gcp-infra/sops-check.tf
```

- [ ] **Step 8: fmt + validate skeleton (may fail without credentials; still run fmt)**

```bash
tofu fmt -recursive tofu/modules/node-gcp tofu/modules/gcp-account-infra tofu/layers/02-gcp-infra
```

- [ ] **Step 9: Commit**

```bash
git add tofu/layers/02-gcp-infra scripts/sync-sops-check.sh
git commit -m "feat(gcp): OpenTofu layer 02-gcp-infra"
```

---

### Task 8: Layer 03 + patch template

**Files:**
- Create: `tofu/shared/patches/node-gcp.tftpl`
- Modify: `tofu/layers/03-talos/main.tf` — remote state + merge for gcp
- Modify: `tofu/layers/03-talos/per-node-patches.tf` — include provider `gcp`

- [ ] **Step 1: node-gcp.tftpl**

```yaml
---
# tofu/shared/patches/node-gcp.tftpl
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
```

- [ ] **Step 2: main.tf remote state**

Add after onprem remote state blocks (same pattern as oracle):

```hcl
data "terraform_remote_state" "gcp" {
  for_each = toset(try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).gcp, []))
  backend  = "s3"
  config = {
    bucket                      = "cluster-tofu-state"
    key                         = "production/02-gcp-infra-${each.key}.tfstate"
    region                      = "auto"
    # same R2 flags as other remote_state blocks in this file
  }
}

locals {
  gcp_outputs_nodes = merge([
    for k, s in data.terraform_remote_state.gcp :
    try(s.outputs.nodes, {})
  ]...)
}
```

Include `local.gcp_outputs_nodes` in the merge that builds `all_nodes_from_state`.

Add `gcp` to the inventory provider_data pair list:

```hcl
gcp = try(yamldecode(file("${path.module}/../../shared/accounts.yaml")).gcp, [])
```

- [ ] **Step 3: per-node-patches.tf**

Change eligibility to:

```hcl
if contains(["contabo", "oracle", "gcp"], try(v.provider, ""))
```

Extend the render ternary (or convert to a lookup map) so `v.provider == "gcp"` uses `node-gcp.tftpl` with `hostname`, `node_labels`, `node_annotations` like oracle.

- [ ] **Step 4: Commit**

```bash
git add tofu/shared/patches/node-gcp.tftpl tofu/layers/03-talos
git commit -m "feat(gcp): layer 03 remote state and per-node patches"
```

---

### Task 9: CI — tofu-layer, plan, apply, cluster-provision

**Files:**
- Modify: `.github/workflows/tofu-layer.yml`
- Modify: `.github/workflows/tofu-plan.yml`
- Modify: `.github/workflows/tofu-apply.yml`
- Modify: `.github/workflows/cluster-provision.yml`

- [ ] **Step 1: tofu-layer.yml**

1. Extend layer backend-key switch to include `02-gcp-infra` with key `production/02-gcp-infra-${account}.tfstate` and `TF_VAR_account_key`.
2. When `layer == 02-gcp-infra`:
   - Install `google-github-actions/auth@v2` (or current) after staging auth:
     ```bash
     scripts/stage-gcp-auth-from-repo.sh /tmp/gcp-auth .
     # read project/WIF/SA for inputs.account from /tmp/gcp-auth/<account>/auth.yaml
     ```
   - Auth action inputs from that YAML: `workload_identity_provider`, `service_account`.
   - Sync inventory: `aws s3 sync s3://…/production/inventory/gcp/ /tmp/inventory/gcp/`
3. Add `02-gcp-infra` to any layer allow-lists that currently list oracle/onprem/contabo.

- [ ] **Step 2: tofu-plan.yml + tofu-apply.yml**

Add jobs parallel to oracle:

```yaml
  read-gcp-accounts:
    needs: secrets
    runs-on: ubuntu-latest
    outputs:
      accounts: ${{ steps.read.outputs.accounts }}
      count: ${{ steps.read.outputs.count }}
    steps:
      - uses: actions/checkout@v5
      - id: read
        run: |
          set -euo pipefail
          accounts=$(yq -o=json '.gcp // []' tofu/shared/accounts.yaml | jq -c .)
          count=$(jq 'length' <<<"$accounts")
          echo "accounts=$accounts" >> "$GITHUB_OUTPUT"
          echo "count=$count" >> "$GITHUB_OUTPUT"

  gcp-infra:
    needs: read-gcp-accounts
    if: needs.read-gcp-accounts.outputs.count != '0'
    strategy:
      fail-fast: false
      matrix:
        account: ${{ fromJson(needs.read-gcp-accounts.outputs.accounts) }}
    uses: ./.github/workflows/tofu-layer.yml
    with:
      layer: 02-gcp-infra
      account: ${{ matrix.account }}
      mode: plan   # or apply in tofu-apply.yml
    secrets: inherit
```

Update `03-talos` `needs` / `if` chains to include `gcp-infra` without blocking when count is 0:

```yaml
if: always() && needs.contabo-infra.result != 'cancelled' && needs.oracle-infra.result != 'cancelled' && needs.onprem-infra.result != 'cancelled' && (needs.gcp-infra.result == 'skipped' || needs.gcp-infra.result != 'cancelled')
```

(Adjust exact expression so empty `gcp: []` still runs talos.)

- [ ] **Step 3: cluster-provision.yml**

Where oracle free-tier validation / image / apply matrix is invoked, add parallel GCP ensure-default-capacity (optional, onboard owns seed) and ensure image+apply paths cover `02-gcp-infra`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/tofu-layer.yml .github/workflows/tofu-plan.yml \
  .github/workflows/tofu-apply.yml .github/workflows/cluster-provision.yml
git commit -m "ci(gcp): wire 02-gcp-infra into plan/apply/provision matrix"
```

---

### Task 10: sync-talos-images GCP legs

**Files:**
- Modify: `.github/workflows/sync-talos-images.yml`

- [ ] **Step 1: build job**

After oracle download, also download GCP amd64 Omni image via the same `omnictl download` helper. Cache object key like `talos-${VERSION}-${schematic}-gcp-amd64.tar.gz` (or raw format omnictl emits). Export outputs: `gcp_image_file`, `gcp_image_sha256`.

Confirm platform name with:

```bash
omnictl download --help   # or docs; use the platform id Omni expects for GCE
```

Pin that id in workflow comments.

- [ ] **Step 2: discover-gcp job**

```yaml
  discover-gcp:
    # stage auth, read accounts.yaml gcp list, emit JSON matrix
    # [{account, project_id, region, workload_identity_provider, service_account_email}]
```

- [ ] **Step 3: gcp-import matrix**

Per account:

1. WIF auth
2. Ensure GCS bucket `stawi-talos-images-<account>` (or project-level name)
3. Upload image object if missing for this sha
4. `gcloud compute images create` / `google_compute_image` equivalent with family `stawi-talos` and name including schematic+sha
5. Skip create if image with same name exists
6. Emit artifact JSON: `{account, self_link, family, schematic_id, sha256}`

- [ ] **Step 4: assemble**

Merge into `talos-images.yaml`:

```yaml
formats:
  gcp:
    accounts:
      <account>:
        self_link: projects/.../global/images/...
        schematic_id: ...
        sha256: ...
```

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/sync-talos-images.yml
git commit -m "ci(gcp): sync-talos-images import per project"
```

---

### Task 11: bootstrap-gcp-wif.sh + onboard-gcp.yml

**Files:**
- Create: `scripts/bootstrap-gcp-wif.sh` (mode `0755`)
- Create: `.github/workflows/onboard-gcp.yml`
- Modify: `scripts/README.md`

- [ ] **Step 1: Bootstrap script structure**

Mirror `bootstrap-oci-oidc.sh` phases:

1. Parse flags: `--project`, `--region` (default `europe-west1`), `--gh-profile`, `--vpc-cidr` (default `10.210.0.0/16`), `--repo-path`, `--base-branch`, `--branch`, `--no-push`, `--no-pr`, budget flags.
2. Require `gcloud`, `jq`, `curl`, `python3`, `git`, `sops` (reuse ensure_sops pattern from OCI script), `GITHUB_TOKEN`.
3. Idempotent GCP setup:
   - Enable APIs: `compute.googleapis.com`, `iam.googleapis.com`, `iamcredentials.googleapis.com`, `cloudresourcemanager.googleapis.com`, `sts.googleapis.com`, `storage.googleapis.com`
   - Pool `github` + provider `github-actions` with issuer `https://token.actions.githubusercontent.com`
   - Attribute mapping: `google.subject=assertion.sub`, `attribute.repository=assertion.repository`, `attribute.ref=assertion.ref`
   - Condition: `assertion.repository=='stawi-org/deployment.infra'`
   - SA `tofu-gcp@PROJECT.iam.gserviceaccount.com`
   - Roles on SA: `roles/compute.admin`, `roles/compute.networkAdmin`, `roles/iam.serviceAccountUser`, `roles/storage.admin` (tighten later if possible)
   - Bind WIF principal set to SA `roles/iam.workloadIdentityUser`
4. Worktree write:
   - SOPS encrypt auth.yaml under `tofu/shared/accounts/gcp/<gh-profile>/auth.yaml`
   - Add `gh-profile` under `gcp:` in accounts.yaml (idempotent list edit — use Python/yq like OCI)
5. Commit, push `onboard-gcp-<gh-profile>`, open PR via REST.

Auth.yaml plaintext shape before sops:

```yaml
auth:
  project_id: "..."
  region: "europe-west1"
  vpc_cidr: "10.210.0.0/16"
  workload_identity_provider: "projects/NUM/locations/global/workloadIdentityPools/github/providers/github-actions"
  service_account_email: "tofu-gcp@PROJECT.iam.gserviceaccount.com"
```

- [ ] **Step 2: onboard-gcp.yml**

Copy structure from `onboard-oracle.yml` (if not on branch, use the design):

```yaml
name: onboard-gcp
on:
  push:
    branches: [main]
    paths:
      - tofu/shared/accounts.yaml
      - tofu/shared/accounts/gcp/**
      - .github/workflows/onboard-gcp.yml
  workflow_dispatch:
    inputs:
      deploy_flux: { type: boolean, default: false }
      dry_run: { type: boolean, default: false }

jobs:
  seed-default-nodes:
    # sync R2 inventory/gcp
    # stage auth for regions
    # python3 scripts/ensure-gcp-default-capacity.py --write
    # upload nodes.yaml
  provision:
    needs: seed-default-nodes
    if: dry_run is false
    uses: ./.github/workflows/cluster-provision.yml
    with:
      mode: full
      wipe_cluster: false
      deploy_flux: ${{ ... }}
    secrets: inherit
```

- [ ] **Step 3: scripts/README.md**

Document both new scripts in the table.

- [ ] **Step 4: Commit**

```bash
git add scripts/bootstrap-gcp-wif.sh .github/workflows/onboard-gcp.yml scripts/README.md
git commit -m "feat(gcp): bootstrap WIF PR flow and onboard-gcp workflow"
```

---

### Task 12: Docs + example config

**Files:**
- Create: `docs/config/gcp/stawi-prod.yaml` (example only)
- Modify: `README.md` — architecture diagram + inventory table + secrets note (WIF, no JSON keys)
- Modify: `docs/topology.md` — fourth ownership mode
- Modify: `docs/superpowers/specs/2026-07-22-gcp-workers-design.md` status → approved/implementing if desired

- [ ] **Step 1: Example config**

```yaml
# Example only — live nodes live in R2 production/inventory/gcp/<account>/nodes.yaml
gcp:
  accounts:
    stawi-prod:
      project_id: stawi-prod-123456
      region: europe-west1
      vpc_cidr: 10.210.0.0/16
      labels:
        node.stawi.org/capacity-pool: gce-spot
      nodes:
        gcp-stawi-prod-node-1:
          role: worker
          machine_type: e2-medium
          zone: europe-west1-b
          boot_disk_gb: 50
          preemptible: true
        gcp-stawi-prod-node-2:
          role: worker
          machine_type: e2-medium
          zone: europe-west1-b
          boot_disk_gb: 50
          preemptible: true
```

- [ ] **Step 2: Topology blurb**

Add mode 4: **GCP nodes** — layer `02-gcp-infra`, two Spot workers default, WIF, workers only.

- [ ] **Step 3: Commit**

```bash
git add docs README.md
git commit -m "docs(gcp): topology, README, example inventory for Spot workers"
```

---

### Task 13: Live onboard smoke (operator / post-merge)

Not fully automatable in CI without a real project.

- [ ] **Step 1: Operator runs bootstrap against a real project**

```bash
export GITHUB_TOKEN=...
./scripts/bootstrap-gcp-wif.sh --project YOUR_PROJECT_ID --gh-profile demo --region europe-west1
```

- [ ] **Step 2: Merge PR; watch `onboard-gcp` + `sync-talos-images` + `02-gcp-infra`**

Expected:

- R2 `production/inventory/gcp/demo/nodes.yaml` has **two** Spot nodes
- Two GCE Spot VMs exist
- Omni shows two machines with `node.stawi.org/provider=gcp` and `role=worker`
- Machines enter `workers` MachineClass

- [ ] **Step 3: Record any runtime gaps as follow-up issues** (image platform id, firewall, flannel annotations)

---

## Spec coverage checklist

| Spec requirement | Task |
|---|---|
| Multi-project roster + empty-safe matrix | 1, 9 |
| WIF auth.yaml (no JSON keys) | 4, 11 |
| Bootstrap PR + onboard workflow | 11 |
| Default **2 Spot** workers per empty account | 2, 3 |
| `preemptible` / Spot scheduling on instances | 5 |
| VPC/firewall/public IPv4 | 6 |
| Image pipeline per project | 10 |
| Layer 02-gcp-infra + nodes writer | 7 |
| Layer 03 patches + remote state | 8 |
| Workers only validation | 2, 5 |
| Docs | 12 |
| Live acceptance | 13 |

## Placeholder / consistency review

- Node keys: always `gcp-<account>-node-N` in seed and examples.
- `preemptible: true` default in pack, module variable, and inventory object.
- Provider string in contracts: `"gcp"` (matches inventory path and Machine labels).
- Empty `gcp: []` must not break plan/apply (count gate on matrix jobs).

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-07-22-gcp-workers-plan.md`.

**Two execution options:**

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks
2. **Inline Execution** — execute tasks in this session with checkpoints

Which approach?
