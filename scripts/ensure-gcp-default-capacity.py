#!/usr/bin/env python3
"""Seed empty GCP account inventories with the default two Spot workers.

Usage:
  python3 scripts/ensure-gcp-default-capacity.py \
    --inventory-dir /tmp/inventory/gcp \
    --accounts-yaml tofu/shared/accounts.yaml \
    --auth-dir /tmp/gcp-auth-from-repo \
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

    for acct in accounts:
        region = _region_for_account(args.auth_dir, acct)
        path = args.inventory_dir / acct / "nodes.yaml"
        line, changed = ensure_account(acct, path, region=region, write=args.write)
        print(line)
        if line.startswith(f"{acct}: ERROR"):
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
