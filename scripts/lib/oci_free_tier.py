"""OCI Always Free inventory validation and reconciliation helpers.

Caps match Oracle docs as of 2026-06-15:
  https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm

  - Ampere A1: 2 OCPU + 12 GB memory continuous per tenancy
  - ≤2 A1 instances
  - Block volume: 200 GB total (boot + data)
  - Shape: VM.Standard.A1.Flex only
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

A1_SHAPE = "VM.Standard.A1.Flex"
MAX_OCPU = 2
MAX_MEMORY_GB = 12
MAX_BOOT_GB = 200
MAX_NODES = 2
DEFAULT_BOOT_GB = 100
MIN_BOOT_GB = 50
MIN_MEMORY_PER_NODE = 6


@dataclass
class Violation:
    account: str
    code: str
    message: str


@dataclass
class AccountReport:
    account: str
    node_count: int = 0
    ocpus: int = 0
    memory_gb: int = 0
    boot_gb: int = 0
    violations: list[Violation] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.violations


def _boot_for_node(node: dict[str, Any]) -> int:
    raw = node.get("boot_volume_size_gb")
    if raw is None:
        return DEFAULT_BOOT_GB
    return int(raw)


def validate_account(account: str, nodes: dict[str, Any] | None) -> AccountReport:
    """Validate one tenancy's nodes map from R2 nodes.yaml."""
    report = AccountReport(account=account)
    nodes = nodes or {}
    report.node_count = len(nodes)

    if report.node_count > MAX_NODES:
        report.violations.append(
            Violation(
                account,
                "node_count",
                f"{report.node_count} nodes exceeds Always Free max of {MAX_NODES}",
            )
        )

    for name, node in nodes.items():
        if not isinstance(node, dict):
            report.violations.append(
                Violation(account, "node_shape", f"{name}: node entry is not a mapping")
            )
            continue
        shape = node.get("shape") or A1_SHAPE
        if shape != A1_SHAPE:
            report.violations.append(
                Violation(
                    account,
                    "shape",
                    f"{name}: shape {shape!r} is not Always Free A1 ({A1_SHAPE})",
                )
            )
        ocpus = int(node.get("ocpus") or 0)
        mem = int(node.get("memory_gb") or 0)
        boot = _boot_for_node(node)
        report.ocpus += ocpus
        report.memory_gb += mem
        report.boot_gb += boot
        if ocpus < 1:
            report.violations.append(
                Violation(account, "ocpus", f"{name}: ocpus must be >= 1")
            )
        if mem < MIN_MEMORY_PER_NODE:
            report.violations.append(
                Violation(
                    account,
                    "memory",
                    f"{name}: memory_gb={mem} < {MIN_MEMORY_PER_NODE}",
                )
            )
        if boot < MIN_BOOT_GB or boot > MAX_BOOT_GB:
            report.violations.append(
                Violation(
                    account,
                    "boot",
                    f"{name}: boot_volume_size_gb={boot} out of [{MIN_BOOT_GB},{MAX_BOOT_GB}]",
                )
            )

    if report.ocpus > MAX_OCPU:
        report.violations.append(
            Violation(
                account,
                "ocpu_total",
                f"sum(ocpus)={report.ocpus} exceeds Always Free cap {MAX_OCPU}",
            )
        )
    if report.memory_gb > MAX_MEMORY_GB:
        report.violations.append(
            Violation(
                account,
                "memory_total",
                f"sum(memory_gb)={report.memory_gb} exceeds Always Free cap {MAX_MEMORY_GB}",
            )
        )
    if report.boot_gb > MAX_BOOT_GB:
        report.violations.append(
            Violation(
                account,
                "boot_total",
                f"sum(boot)={report.boot_gb} exceeds Always Free block cap {MAX_BOOT_GB}",
            )
        )
    return report


def validate_inventory_tree(accounts: dict[str, dict[str, Any]]) -> list[AccountReport]:
    """accounts: {account_key: nodes.yaml document or {'nodes': {...}}}."""
    reports = []
    for acct, doc in sorted(accounts.items()):
        nodes = doc.get("nodes") if isinstance(doc, dict) and "nodes" in doc else doc
        if nodes is None:
            nodes = {}
        reports.append(validate_account(acct, nodes))
    return reports


def free_tier_pack(node_count: int) -> list[dict[str, int]]:
    """Return per-node {ocpus, memory_gb, boot_volume_size_gb} for free-tier pack.

    Prefer a single full 2/12/100 node. Two nodes split 1/6/100 each.
    """
    if node_count <= 0:
        return []
    if node_count == 1:
        return [{"ocpus": 2, "memory_gb": 12, "boot_volume_size_gb": DEFAULT_BOOT_GB}]
    if node_count == 2:
        return [
            {"ocpus": 1, "memory_gb": 6, "boot_volume_size_gb": DEFAULT_BOOT_GB},
            {"ocpus": 1, "memory_gb": 6, "boot_volume_size_gb": DEFAULT_BOOT_GB},
        ]
    raise ValueError(f"cannot pack {node_count} nodes into Always Free envelope")


def reconcile_nodes(nodes: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of nodes with free-tier-safe compute/boot sizes.

    Preserves all other fields (role, labels, annotations, provider_data, …).
    Does not delete nodes; if more than MAX_NODES, raises.
    """
    if not nodes:
        return {}
    if len(nodes) > MAX_NODES:
        raise ValueError(
            f"account has {len(nodes)} nodes; delete down to ≤{MAX_NODES} before reconcile"
        )
    packs = free_tier_pack(len(nodes))
    out: dict[str, Any] = {}
    for (name, node), pack in zip(sorted(nodes.items()), packs):
        n = dict(node) if isinstance(node, dict) else {}
        n["shape"] = A1_SHAPE
        n["ocpus"] = pack["ocpus"]
        n["memory_gb"] = pack["memory_gb"]
        n["boot_volume_size_gb"] = pack["boot_volume_size_gb"]
        out[name] = n
    return out
