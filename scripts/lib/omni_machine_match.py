#!/usr/bin/env python3
"""Resolve an Omni Machine UUID for a fleet inventory node.

Matching priority (first hit wins):

  1. preferred_id — if that UUID still exists in Omni inventory
     - Prefer it when connected
     - If disconnected but a connected hostname twin exists, prefer the twin
       (twin recovery: free-tier resize / re-register cases)
     - If no connected twin, keep preferred_id (stable pin while offline)
  2. hostname — all machines with matching spec.network.hostname
     - Prefer connected=true; stable sort by id among ties
  3. ipv4 — any address (CIDR-stripped) equals the node ipv4
     - Prefer connected=true; stable sort by id

This module is the single source of truth used by:
  - scripts/reconcile-omni-machine-ids.py (persist id into R2 inventory)
  - tofu/layers/03-talos/scripts/sync-machine-label.sh
  - tofu/layers/03-talos/scripts/apply-per-node-patches.sh

CLI:
  python3 scripts/lib/omni_machine_match.py \\
    --machines-file /tmp/ms.json \\
    --preferred-id <uuid-or-empty> \\
    --hostname oci-bwire-node-1 \\
    --ipv4 1.2.3.4

Prints matched machine id on stdout (empty if none). Exit 0 always
unless bad args / invalid JSON (exit 2).
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


def _pick_best(candidates: list[dict[str, Any]]) -> dict[str, Any] | None:
    if not candidates:
        return None
    # Prefer connected; among equals, stable by id.
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
        # Stale pin: if hostname has a connected twin, follow the twin.
        if host:
            twins = [m for m in machines if _hostname(m) == host and _connected(m)]
            best_twin = _pick_best(twins)
            if best_twin and _id(best_twin) != preferred:
                return MatchResult(_id(best_twin), "preferred_stale_twin")
        return MatchResult(preferred, "preferred")

    if host:
        hosts = [m for m in machines if _hostname(m) == host]
        best = _pick_best(hosts)
        if best:
            return MatchResult(_id(best), "hostname")

    if ip:
        ips = [
            m
            for m in machines
            if any(_addr_ip(a) == ip for a in _addresses(m))
        ]
        best = _pick_best(ips)
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
    )
    if args.print_reason:
        print(f"{result.machine_id}\t{result.reason}")
    else:
        print(result.machine_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
