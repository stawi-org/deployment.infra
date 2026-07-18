#!/usr/bin/env python3
"""Ensure every oracle account inventory uses fleet target capacity.

Policy:
  - worker:       4 OCPU / 24 GB
  - controlplane: 2 OCPU / 12 GB
  - boot:         sum ≤ 196 GB (Always Free 200 GB − 4 GB buffer)
  - Empty accounts: seed one worker at free_tier_pack(1) = 4/24/196
  - Non-empty accounts: reconcile shape/ocpus/memory/boot to role pack
    without deleting nodes (caller must drop nodes >2 first)
  - Does NOT destroy live VMs; only rewrites R2 inventory YAML

Usage:
  python3 scripts/ensure-oci-free-tier-capacity.py \\
    --inventory-dir /tmp/inventory/oracle --accounts-yaml tofu/shared/accounts.yaml \\
    --write
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from oci_free_tier import (  # noqa: E402
    A1_SHAPE,
    free_tier_pack,
    reconcile_nodes,
    validate_account,
)


def _load_accounts(path: Path) -> list[str]:
    doc = yaml.safe_load(path.read_text()) or {}
    return list(doc.get("oracle") or [])


def _default_worker(name: str, pack: dict) -> dict:
    return {
        "role": "worker",
        "shape": A1_SHAPE,
        "ocpus": pack["ocpus"],
        "memory_gb": pack["memory_gb"],
        "boot_volume_size_gb": pack["boot_volume_size_gb"],
        "labels": {
            "node.stawi.org/plane": "worker",
            "node.stawi.org/external-load-balancer": "true",
        },
        "annotations": {
            "node.stawi.org/operator-note": (
                f"fleet pack {pack['ocpus']}/{pack['memory_gb']}/"
                f"{pack['boot_volume_size_gb']} worker"
            ),
        },
    }


def ensure_account(account: str, path: Path, write: bool) -> tuple[str, bool]:
    """Return (status_line, changed)."""
    if path.is_file():
        doc = yaml.safe_load(path.read_text()) or {}
    else:
        doc = {
            "labels": {"node.stawi.org/account": account},
            "annotations": {"node.stawi.org/account-owner": "platform"},
            "nodes": {},
        }

    nodes = doc.get("nodes") or {}
    changed = False

    if not nodes:
        pack = free_tier_pack(1)[0]
        name = f"oci-{account}-node-1"
        nodes = {name: _default_worker(name, pack)}
        doc["nodes"] = nodes
        if "labels" not in doc:
            doc["labels"] = {"node.stawi.org/account": account}
        if "annotations" not in doc:
            doc["annotations"] = {"node.stawi.org/account-owner": "platform"}
        changed = True
        action = (
            f"seeded {name} as {pack['ocpus']}/{pack['memory_gb']}/"
            f"{pack['boot_volume_size_gb']}"
        )
    else:
        try:
            new_nodes = reconcile_nodes(nodes)
        except ValueError as e:
            return (f"{account}: ERROR {e}", False)
        # Detect size field drift only
        before = {
            k: (v.get("ocpus"), v.get("memory_gb"), v.get("boot_volume_size_gb"), v.get("shape"))
            for k, v in sorted(nodes.items())
        }
        after = {
            k: (v.get("ocpus"), v.get("memory_gb"), v.get("boot_volume_size_gb"), v.get("shape"))
            for k, v in sorted(new_nodes.items())
        }
        if before != after:
            doc["nodes"] = new_nodes
            nodes = new_nodes
            changed = True
            action = "reconciled sizes to fleet role pack"
        else:
            action = "already at fleet target pack"

    report = validate_account(account, nodes)
    if not report.ok:
        return (f"{account}: INVALID after ensure: {report.violations}", False)

    if changed and write:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False))
        action += f" (wrote {path})"
    elif changed:
        action += " (dry-run)"

    return (
        f"{account}: {action} | nodes={report.node_count} "
        f"ocpu={report.ocpus} mem={report.memory_gb} boot={report.boot_gb}",
        changed,
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inventory-dir", type=Path, required=True)
    ap.add_argument("--accounts-yaml", type=Path, required=True)
    ap.add_argument("--write", action="store_true")
    args = ap.parse_args()

    accounts = _load_accounts(args.accounts_yaml)
    if not accounts:
        print("ERROR: no oracle accounts in accounts.yaml", file=sys.stderr)
        return 2

    any_change = False
    errors = 0
    for acct in accounts:
        path = args.inventory_dir / acct / "nodes.yaml"
        line, changed = ensure_account(acct, path, args.write)
        print(line)
        if line.startswith(f"{acct}: ERROR") or "INVALID" in line:
            errors += 1
        if changed:
            any_change = True

    if errors:
        return 2
    if any_change and not args.write:
        print("\nchanges needed; re-run with --write")
        return 1
    if any_change:
        print(f"\nensured fleet capacity for inventory under {args.inventory_dir}")
    else:
        print("\nall accounts already at fleet target pack")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
