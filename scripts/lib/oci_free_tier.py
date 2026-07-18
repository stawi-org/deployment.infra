"""OCI Always Free continuous fleet sizing + block-volume guardrails.

Continuous free A1 compute (post 2026-06-15, per tenancy):
  - 2 OCPU + 12 GB memory total (1,500 OCPU-hours + 9,000 GB-hours / month)
  - ≤2 A1 instances sharing that pool
  - shape VM.Standard.A1.Flex only

Packs:
  - 1 node:  2 OCPU / 12 GB / 196 GB boot
  - 2 nodes: 1 OCPU / 6 GB each / 98 GB boot each (even free split)

Always Free block volume (hard — never exceed free envelope):
  - Oracle cap: 200 GB total boot+data per tenancy
  - Operational buffer: 4 GB reserved so provisioning never hits the ceiling
  - Usable boot total: 196 GB (split evenly across nodes)

Oracle docs:
  https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

A1_SHAPE = "VM.Standard.A1.Flex"
MAX_NODES = 2

# Continuous free A1 pool (tenancy totals)
CONTINUOUS_FREE_OCPU = 2
CONTINUOUS_FREE_MEMORY_GB = 12
MIN_MEMORY_PER_NODE = 6

# Solo full free pack
SOLO_OCPU = CONTINUOUS_FREE_OCPU
SOLO_MEMORY_GB = CONTINUOUS_FREE_MEMORY_GB
# Two-node free split
SPLIT_OCPU = 1
SPLIT_MEMORY_GB = 6

# Always Free block volume
MAX_BOOT_HARD_GB = 200
BOOT_BUFFER_GB = 4
MAX_BOOT_USABLE_GB = MAX_BOOT_HARD_GB - BOOT_BUFFER_GB  # 196
MIN_BOOT_GB = 50

# Aliases for callers/tests
MAX_OCPU = CONTINUOUS_FREE_OCPU
MAX_MEMORY_GB = CONTINUOUS_FREE_MEMORY_GB
MAX_BOOT_GB = MAX_BOOT_USABLE_GB
DEFAULT_BOOT_GB = MAX_BOOT_USABLE_GB
# Backward-compat names (solo free pack is the per-node ceiling)
WORKER_OCPU = SOLO_OCPU
WORKER_MEMORY_GB = SOLO_MEMORY_GB
CONTROLPLANE_OCPU = SOLO_OCPU
CONTROLPLANE_MEMORY_GB = SOLO_MEMORY_GB


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


def _boot_for_node(node: dict[str, Any], node_count: int = 1) -> int:
    raw = node.get("boot_volume_size_gb")
    if raw is None:
        return _boot_split(node_count)[0] if node_count else DEFAULT_BOOT_GB
    return int(raw)


def _role_of(node: dict[str, Any]) -> str:
    role = str(node.get("role") or "worker").strip().lower()
    if role in ("controlplane", "control-plane", "cp"):
        return "controlplane"
    return "worker"


def _boot_split(node_count: int) -> list[int]:
    """Even split of usable boot budget; remainder GB goes to the first nodes."""
    if node_count <= 0:
        return []
    base = MAX_BOOT_USABLE_GB // node_count
    rem = MAX_BOOT_USABLE_GB % node_count
    if base < MIN_BOOT_GB:
        raise ValueError(
            f"cannot split {MAX_BOOT_USABLE_GB} GB usable boot across "
            f"{node_count} nodes while keeping each ≥ {MIN_BOOT_GB}"
        )
    return [base + (1 if i < rem else 0) for i in range(node_count)]


def validate_account(account: str, nodes: dict[str, Any] | None) -> AccountReport:
    """Validate one tenancy's nodes map against continuous Always Free caps."""
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
        boot = _boot_for_node(node, report.node_count or 1)
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
        if boot < MIN_BOOT_GB or boot > MAX_BOOT_HARD_GB:
            report.violations.append(
                Violation(
                    account,
                    "boot",
                    f"{name}: boot_volume_size_gb={boot} out of "
                    f"[{MIN_BOOT_GB},{MAX_BOOT_HARD_GB}]",
                )
            )
        # Per-node must not exceed the full continuous free pool alone.
        if ocpus > CONTINUOUS_FREE_OCPU:
            report.violations.append(
                Violation(
                    account,
                    "ocpus_node",
                    f"{name}: ocpus={ocpus} exceeds continuous free pool "
                    f"{CONTINUOUS_FREE_OCPU}",
                )
            )
        if mem > CONTINUOUS_FREE_MEMORY_GB:
            report.violations.append(
                Violation(
                    account,
                    "memory_node",
                    f"{name}: memory_gb={mem} exceeds continuous free pool "
                    f"{CONTINUOUS_FREE_MEMORY_GB}",
                )
            )

    if report.ocpus > CONTINUOUS_FREE_OCPU:
        report.violations.append(
            Violation(
                account,
                "ocpu_total",
                f"sum(ocpus)={report.ocpus} exceeds Always Free cap "
                f"{CONTINUOUS_FREE_OCPU}",
            )
        )
    if report.memory_gb > CONTINUOUS_FREE_MEMORY_GB:
        report.violations.append(
            Violation(
                account,
                "memory_total",
                f"sum(memory_gb)={report.memory_gb} exceeds Always Free cap "
                f"{CONTINUOUS_FREE_MEMORY_GB}",
            )
        )
    if report.boot_gb > MAX_BOOT_USABLE_GB:
        report.violations.append(
            Violation(
                account,
                "boot_total",
                f"sum(boot)={report.boot_gb} exceeds usable Always Free block "
                f"budget {MAX_BOOT_USABLE_GB} "
                f"({MAX_BOOT_HARD_GB} hard cap − {BOOT_BUFFER_GB} GB buffer)",
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


def free_tier_pack(node_count: int, roles: list[str] | None = None) -> list[dict[str, int]]:
    """Return per-node continuous free packs.

    1 node  → 2/12/196
    2 nodes → 1/6/98 each (roles preserved by caller; sizes equal split)
    """
    if node_count <= 0:
        return []
    if node_count > MAX_NODES:
        raise ValueError(
            f"cannot pack {node_count} nodes into Always Free envelope (max {MAX_NODES})"
        )

    if roles is None:
        if node_count == 1:
            roles = ["worker"]
        else:
            roles = ["controlplane", "worker"]
    if len(roles) != node_count:
        raise ValueError("roles length must match node_count")

    boots = _boot_split(node_count)
    packs: list[dict[str, int]] = []
    if node_count == 1:
        packs.append(
            {
                "ocpus": SOLO_OCPU,
                "memory_gb": SOLO_MEMORY_GB,
                "boot_volume_size_gb": boots[0],
            }
        )
    else:
        for boot in boots:
            packs.append(
                {
                    "ocpus": SPLIT_OCPU,
                    "memory_gb": SPLIT_MEMORY_GB,
                    "boot_volume_size_gb": boot,
                }
            )
    return packs


def reconcile_nodes(nodes: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of nodes with continuous free compute/boot sizes.

    Preserves all other fields (role, labels, annotations, provider_data, …).
    Does not delete nodes; if more than MAX_NODES, raises.

    Sizes:
      1 node  → 2 OCPU / 12 GB / 196 GB boot
      2 nodes → 1 OCPU / 6 GB / 98 GB boot each
    """
    if not nodes:
        return {}
    if len(nodes) > MAX_NODES:
        raise ValueError(
            f"account has {len(nodes)} nodes; delete down to ≤{MAX_NODES} before reconcile"
        )
    ordered = sorted(nodes.items())
    roles = [_role_of(n if isinstance(n, dict) else {}) for _, n in ordered]
    packs = free_tier_pack(len(ordered), roles=roles)
    out: dict[str, Any] = {}
    for (name, node), pack in zip(ordered, packs):
        n = dict(node) if isinstance(node, dict) else {}
        n["shape"] = A1_SHAPE
        n["ocpus"] = pack["ocpus"]
        n["memory_gb"] = pack["memory_gb"]
        n["boot_volume_size_gb"] = pack["boot_volume_size_gb"]
        out[name] = n
    return out
