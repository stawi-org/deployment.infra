#!/usr/bin/env python3
"""Persist Omni machine UUIDs into R2 inventory provider_data.

Walks production inventory layout:

  <inventory-root>/{oracle,contabo,onprem}/<account>/nodes.yaml

For each node, resolves the best Omni Machine UUID via omni_machine_match
and writes:

  nodes.<name>.provider_data.omni_machine_id: <uuid>

Does not modify Omni. Does not delete machines. Safe to re-run.

Usage:
  # machines dump from: omnictl get machinestatus -o json | jq -cs flatten
  python3 scripts/reconcile-omni-machine-ids.py \\
    --inventory-dir /tmp/inventory \\
    --machines-file /tmp/ms.json \\
    --write

Without --write, prints a dry-run diff and exits 1 if changes are needed.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
from omni_machine_match import match_machine  # noqa: E402

PROVIDERS = ("oracle", "contabo", "onprem")


def _load_machines(path: Path) -> list:
    data = json.loads(path.read_text())
    if isinstance(data, dict):
        return [data]
    if isinstance(data, list):
        return data
    raise SystemExit(f"machines file must be JSON object or array: {path}")


def _node_ipv4(node: dict) -> str:
    pd = node.get("provider_data") or {}
    return str(pd.get("ipv4") or node.get("ipv4") or "")


def _preferred(node: dict) -> str:
    pd = node.get("provider_data") or {}
    return str(pd.get("omni_machine_id") or "")


def reconcile_file(path: Path, machines: list, write: bool) -> tuple[str, bool]:
    doc = yaml.safe_load(path.read_text()) or {}
    nodes = doc.get("nodes") or {}
    if not nodes:
        return (f"{path}: empty nodes", False)

    changed = False
    lines = []
    for name, node in sorted(nodes.items()):
        if not isinstance(node, dict):
            continue
        pref = _preferred(node)
        ipv4 = _node_ipv4(node)
        result = match_machine(
            machines,
            preferred_id=pref,
            hostname=name,
            ipv4=ipv4,
        )
        if not result.machine_id:
            lines.append(f"  {name}: NO MATCH (preferred={pref or '-'} ipv4={ipv4 or '-'})")
            continue
        if pref == result.machine_id:
            lines.append(f"  {name}: keep {result.machine_id} ({result.reason})")
            continue
        lines.append(
            f"  {name}: {pref or '(none)'} → {result.machine_id} ({result.reason})"
        )
        pd = dict(node.get("provider_data") or {})
        pd["omni_machine_id"] = result.machine_id
        node["provider_data"] = pd
        nodes[name] = node
        changed = True

    if changed and write:
        doc["nodes"] = nodes
        path.write_text(yaml.safe_dump(doc, default_flow_style=False, sort_keys=False))
        header = f"{path}: UPDATED"
    elif changed:
        header = f"{path}: would update"
    else:
        header = f"{path}: ok"

    return (header + "\n" + "\n".join(lines), changed)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--inventory-dir", type=Path, required=True)
    ap.add_argument("--machines-file", type=Path, required=True)
    ap.add_argument("--write", action="store_true")
    ap.add_argument(
        "--providers",
        default=",".join(PROVIDERS),
        help="Comma-separated provider dirs under inventory-dir",
    )
    args = ap.parse_args()

    machines = _load_machines(args.machines_file)
    providers = [p.strip() for p in args.providers.split(",") if p.strip()]

    any_change = False
    for provider in providers:
        root = args.inventory_dir / provider
        if not root.is_dir():
            continue
        for acct_dir in sorted(root.iterdir()):
            if not acct_dir.is_dir():
                continue
            path = acct_dir / "nodes.yaml"
            if not path.is_file():
                continue
            report, changed = reconcile_file(path, machines, args.write)
            print(report)
            print()
            if changed:
                any_change = True

    if any_change and not args.write:
        print("changes needed; re-run with --write")
        return 1
    if any_change:
        print("wrote omni_machine_id updates")
    else:
        print("all nodes already have consistent omni_machine_id pins (or no match)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
