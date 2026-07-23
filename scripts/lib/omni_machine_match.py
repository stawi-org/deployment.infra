#!/usr/bin/env python3
"""Resolve an Omni Machine UUID for a fleet inventory node.

Matching priority (first hit wins):

  1. preferred_id — if that UUID still exists in Omni inventory
     - Prefer it when connected
     - If disconnected but a connected hostname twin exists, prefer the twin
       (twin recovery: Spot recreate / free-tier resize / re-register)
     - If disconnected and no connected twin:
         * require_connected=False → keep preferred pin (offline hold)
         * require_connected=True  → fall through (never label a ghost)
  2. hostname — machines with matching spec.network.hostname
  3. ipv4 — any address (CIDR-stripped) equals the node ipv4

Among candidates, prefer connected=true; stable sort by id among ties.
When require_connected=True, disconnected candidates are never returned
(prevents MachineLabels / ConfigPatches landing on dead twins).

Used by:
  - scripts/reconcile-omni-machine-ids.py
  - tofu/layers/03-talos/scripts/sync-machine-label.sh
  - tofu/layers/03-talos/scripts/apply-per-node-patches.sh
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class MatchResult:
    machine_id: str
    reason: str  # preferred|preferred_stale_twin|hostname|ipv4|none


def _addr_ip(addr: str) -> str:
    return (addr or "").split("/", 1)[0]


def _connected(m: dict[str, Any]) -> bool:
    return bool((m.get("spec") or {}).get("connected"))


def _hostname(m: dict[str, Any]) -> str:
    return str(((m.get("spec") or {}).get("network") or {}).get("hostname") or "")


def _id(m: dict[str, Any]) -> str:
    return str((m.get("metadata") or {}).get("id") or "")


def _addresses(m: dict[str, Any]) -> list[str]:
    return list(((m.get("spec") or {}).get("network") or {}).get("addresses") or [])


def _pick_best(
    candidates: list[dict[str, Any]],
    *,
    require_connected: bool = False,
) -> dict[str, Any] | None:
    if require_connected:
        candidates = [m for m in candidates if _connected(m)]
    if not candidates:
        return None
    ranked = sorted(
        candidates,
        key=lambda m: (0 if _connected(m) else 1, _id(m)),
    )
    return ranked[0]


def match_machine(
    machines: list[dict[str, Any]],
    *,
    preferred_id: str | None = None,
    hostname: str | None = None,
    ipv4: str | None = None,
    require_connected: bool = False,
) -> MatchResult:
    """Return MatchResult for the best Omni machine for this node."""
    by_id = {_id(m): m for m in machines if _id(m)}
    preferred = (preferred_id or "").strip()
    host = (hostname or "").strip()
    ip = (ipv4 or "").strip()

    if preferred and preferred in by_id:
        pref = by_id[preferred]
        if _connected(pref):
            return MatchResult(preferred, "preferred")
        # Stale pin: follow a connected hostname twin if present.
        if host:
            twins = [m for m in machines if _hostname(m) == host]
            best_twin = _pick_best(twins, require_connected=True)
            if best_twin and _id(best_twin) != preferred:
                return MatchResult(_id(best_twin), "preferred_stale_twin")
        if not require_connected:
            # Inventory pin hold while the machine is offline (no twin).
            return MatchResult(preferred, "preferred")
        # Labeling/patch path: never target a disconnected preferred.

    if host:
        hosts = [m for m in machines if _hostname(m) == host]
        best = _pick_best(hosts, require_connected=require_connected)
        if best:
            return MatchResult(_id(best), "hostname")

    if ip:
        ips = [
            m
            for m in machines
            if any(_addr_ip(a) == ip for a in _addresses(m))
        ]
        best = _pick_best(ips, require_connected=require_connected)
        if best:
            return MatchResult(_id(best), "ipv4")

    return MatchResult("", "none")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--machines-file",
        required=True,
        help="Path to JSON array of Omni MachineStatus objects (or NDJSON flattened)",
    )
    ap.add_argument("--preferred-id", default="")
    ap.add_argument("--hostname", default="")
    ap.add_argument("--ipv4", default="")
    ap.add_argument(
        "--require-connected",
        action="store_true",
        help="Never return a disconnected machine (use for labels/patches)",
    )
    ap.add_argument(
        "--print-reason",
        action="store_true",
        help="Print '<id>\\t<reason>' instead of just id",
    )
    args = ap.parse_args(argv)

    raw = open(args.machines_file).read()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        print(f"invalid machines JSON: {e}", file=sys.stderr)
        return 2

    if isinstance(data, dict):
        machines = [data]
    elif isinstance(data, list):
        machines = data
    else:
        print("machines JSON must be object or array", file=sys.stderr)
        return 2

    result = match_machine(
        machines,
        preferred_id=args.preferred_id,
        hostname=args.hostname,
        ipv4=args.ipv4,
        require_connected=args.require_connected,
    )
    if args.print_reason:
        print(f"{result.machine_id}\t{result.reason}")
    else:
        print(result.machine_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
