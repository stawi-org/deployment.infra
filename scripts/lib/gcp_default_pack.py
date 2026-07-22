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
