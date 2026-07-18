#!/usr/bin/env python3
"""Rewrite OCI nodes.yaml files to continuous Always Free packs.

Preserves roles, labels, annotations, provider_data. Only rewrites
shape / ocpus / memory_gb / boot_volume_size_gb.

  1 node  → 2 OCPU / 12 GB / 196 GB boot
  2 nodes → 1 OCPU / 6 GB / 98 GB boot each


Usage:
  python3 scripts/reconcile-oci-free-tier-inventory.py \\
    --inventory-dir /tmp/inventory/oracle --write

  Without --write, prints a dry-run diff summary and exits 0 if already
  compliant, 1 if changes would be required (or validation fails).
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from oci_free_tier import reconcile_nodes, validate_account  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inventory-dir", type=Path, required=True)
    ap.add_argument(
        "--write",
        action="store_true",
        help="Write reconciled nodes.yaml files (default: dry-run)",
    )
    args = ap.parse_args()

    if not args.inventory_dir.is_dir():
        print(f"ERROR: {args.inventory_dir} is not a directory", file=sys.stderr)
        return 2

    changed = 0
    errors = 0
    for entry in sorted(args.inventory_dir.iterdir()):
        if not entry.is_dir():
            continue
        path = entry / "nodes.yaml"
        if not path.is_file():
            print(f"{entry.name}: no nodes.yaml (skip)")
            continue
        doc = yaml.safe_load(path.read_text()) or {}
        nodes = doc.get("nodes") or {}
        if not nodes:
            print(f"{entry.name}: empty nodes (ok)")
            continue
        try:
            new_nodes = reconcile_nodes(nodes)
        except ValueError as e:
            print(f"{entry.name}: ERROR {e}", file=sys.stderr)
            errors += 1
            continue
        report = validate_account(entry.name, new_nodes)
        if not report.ok:
            print(f"{entry.name}: reconcile still invalid: {report.violations}", file=sys.stderr)
            errors += 1
            continue

        before = {
            k: {
                "ocpus": v.get("ocpus"),
                "memory_gb": v.get("memory_gb"),
                "boot_volume_size_gb": v.get("boot_volume_size_gb"),
                "shape": v.get("shape"),
            }
            for k, v in sorted(nodes.items())
        }
        after = {
            k: {
                "ocpus": v.get("ocpus"),
                "memory_gb": v.get("memory_gb"),
                "boot_volume_size_gb": v.get("boot_volume_size_gb"),
                "shape": v.get("shape"),
            }
            for k, v in sorted(new_nodes.items())
        }
        if before == after:
            print(f"{entry.name}: already continuous free pack")
            continue

        print(f"{entry.name}: would update")
        for name in after:
            print(f"  {name}: {before.get(name)} → {after[name]}")
        changed += 1
        if args.write:
            doc["nodes"] = new_nodes
            path.write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False))
            print(f"  wrote {path}")

    if errors:
        return 2
    if changed and not args.write:
        print(f"\n{changed} account(s) need reconcile; re-run with --write")
        return 1
    if changed:
        print(f"\nreconciled {changed} account(s) to continuous free packs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
