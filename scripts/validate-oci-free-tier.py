#!/usr/bin/env python3
"""Validate OCI inventory under continuous Always Free caps.

Usage:
  # Local tree of per-account nodes.yaml files:
  python3 scripts/validate-oci-free-tier.py --inventory-dir /tmp/inventory/oracle

  # Exit 0 if all accounts OK; exit 1 with a report otherwise.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

# Allow `from oci_free_tier import ...` when run as a script.
sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from oci_free_tier import validate_inventory_tree  # noqa: E402


def load_tree(inventory_dir: Path) -> dict:
    accounts = {}
    if not inventory_dir.is_dir():
        raise SystemExit(f"inventory dir not found: {inventory_dir}")
    for entry in sorted(inventory_dir.iterdir()):
        if not entry.is_dir():
            continue
        nodes_path = entry / "nodes.yaml"
        if not nodes_path.is_file():
            accounts[entry.name] = {"nodes": {}}
            continue
        data = yaml.safe_load(nodes_path.read_text()) or {}
        accounts[entry.name] = data
    return accounts


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--inventory-dir",
        type=Path,
        required=True,
        help="Directory containing <account>/nodes.yaml (R2 oracle inventory layout)",
    )
    ap.add_argument(
        "--strict-empty",
        action="store_true",
        help="Fail if no accounts found (default: empty tree is OK)",
    )
    args = ap.parse_args()

    tree = load_tree(args.inventory_dir)
    if not tree and args.strict_empty:
        print("ERROR: no accounts found under", args.inventory_dir, file=sys.stderr)
        return 1

    reports = validate_inventory_tree(tree)
    failed = [r for r in reports if not r.ok]

    print(f"{'account':<16} {'nodes':>5} {'ocpu':>5} {'mem':>5} {'boot':>5}  status")
    print("-" * 56)
    for r in reports:
        status = "OK" if r.ok else "FAIL"
        print(
            f"{r.account:<16} {r.node_count:>5} {r.ocpus:>5} {r.memory_gb:>5} {r.boot_gb:>5}  {status}"
        )
        for v in r.violations:
            print(f"  - [{v.code}] {v.message}")

    if failed:
        print(
            f"\n{len(failed)} account(s) exceed continuous Always Free caps. "
            "See docs/oci-always-free.md",
            file=sys.stderr,
        )
        return 1
    print("\nAll accounts within continuous Always Free (≤2 OCPU / ≤12 GB / boot ≤196).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
