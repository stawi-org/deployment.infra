"""OCI fleet sizing + Always Free block-volume guardrails.

Fleet compute policy (intentional; may use monthly free OCPU-hours then PAYG):
  - single worker:              4 OCPU + 24 GB memory
  - controlplane (any):         2 OCPU + 12 GB memory
  - worker sharing with a CP:   2 OCPU + 12 GB (balanced HA; not 4/24)
  - shape:                      VM.Standard.A1.Flex only
  - ≤2 A1 instances per tenancy

Always Free block volume (hard — never exceed free envelope):
  - Oracle cap: 200 GB total boot+data per tenancy
  - Operational buffer: 4 GB reserved so provisioning never hits the ceiling
  - Usable boot total: 196 GB (split evenly across nodes)

Continuous free A1 compute is 2 OCPU + 12 GB *total* per tenancy. A CP+worker
pair at 2/12 each (4/24 total) uses free monthly OCPU-hours then may bill.
Strict continuous-free two-node packs would be 1/6 each — not the fleet default.

Oracle docs (2026-06-15):
  https://docs.oracle.com/en-us/iaas/Content/FreeTier/freetier_topic-Always_Free_Resources.htm
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

A1_SHAPE = "VM.Standard.A1.Flex"
MAX_NODES = 2

# Role-based fleet targets
WORKER_OCPU = 4
WORKER_MEMORY_GB = 24
CONTROLPLANE_OCPU = 2
CONTROLPLANE_MEMORY_GB = 12

# Always Free block volume
MAX_BOOT_HARD_GB = 200
BOOT_BUFFER_GB = 4
MAX_BOOT_USABLE_GB = MAX_BOOT_HARD_GB - BOOT_BUFFER_GB  # 196
MIN_BOOT_GB = 50

# Continuous free A1 (reporting / optional strict free mode only)
CONTINUOUS_FREE_OCPU = 2
CONTINUOUS_FREE_MEMORY_GB = 12
MIN_MEMORY_PER_NODE = 6

# Backward-compat aliases used by older callers/tests
MAX_OCPU = WORKER_OCPU  # per-tenancy fleet max when single full worker
MAX_MEMORY_GB = WORKER_MEMORY_GB
MAX_BOOT_GB = MAX_BOOT_USABLE_GB
DEFAULT_BOOT_GB = MAX_BOOT_USABLE_GB


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


def _target_for_role(role: str, *, shared_tenancy: bool = False) -> dict[str, int]:
    """Per-role size. Workers sharing a tenancy with a control plane use 2/12."""
    if role == "controlplane":
        return {"ocpus": CONTROLPLANE_OCPU, "memory_gb": CONTROLPLANE_MEMORY_GB}
    if shared_tenancy:
        # Balanced HA with CP: both nodes 2 OCPU / 12 GB (not a solo 4/24 worker).
        return {"ocpus": CONTROLPLANE_OCPU, "memory_gb": CONTROLPLANE_MEMORY_GB}
    return {"ocpus": WORKER_OCPU, "memory_gb": WORKER_MEMORY_GB}


def _boot_split(node_count: int) -> list[int]:
    """Even split of usable boot budget; remainder GB goes to the first nodes."""
    if node_count <= 0:
        return []
    base = MAX_BOOT_USABLE_GB // node_count
    rem = MAX_BOOT_USABLE_GB % node_count
    # Floor per node must still meet Talos QCOW2 minimum.
    if base < MIN_BOOT_GB:
        raise ValueError(
            f"cannot split {MAX_BOOT_USABLE_GB} GB usable boot across "
            f"{node_count} nodes while keeping each ≥ {MIN_BOOT_GB}"
        )
    return [base + (1 if i < rem else 0) for i in range(node_count)]


def validate_account(account: str, nodes: dict[str, Any] | None) -> AccountReport:
    """Validate one tenancy's nodes map from R2 nodes.yaml against fleet policy."""
    report = AccountReport(account=account)
    nodes = nodes or {}
    report.node_count = len(nodes)

    if report.node_count > MAX_NODES:
        report.violations.append(
            Violation(
                account,
                "node_count",
                f"{report.node_count} nodes exceeds max of {MAX_NODES}",
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
                    f"{name}: shape {shape!r} is not A1 ({A1_SHAPE})",
                )
            )
        role = _role_of(node)
        # Ceilings stay at solo fleet max (worker ≤4/24, CP ≤2/12).
        target = _target_for_role(role, shared_tenancy=False)
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
        if ocpus > target["ocpus"]:
            report.violations.append(
                Violation(
                    account,
                    "ocpus_role",
                    f"{name}: role={role} ocpus={ocpus} exceeds fleet target "
                    f"{target['ocpus']}",
                )
            )
        if mem > target["memory_gb"]:
            report.violations.append(
                Violation(
                    account,
                    "memory_role",
                    f"{name}: role={role} memory_gb={mem} exceeds fleet target "
                    f"{target['memory_gb']}",
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
    """Return per-node {ocpus, memory_gb, boot_volume_size_gb} for fleet pack.

    When roles is provided (len == node_count), sizes follow each role.
    Otherwise defaults: one worker, or worker+controlplane for two nodes.
    """
    if node_count <= 0:
        return []
    if node_count > MAX_NODES:
        raise ValueError(f"cannot pack {node_count} nodes into fleet envelope (max {MAX_NODES})")

    if roles is None:
        if node_count == 1:
            roles = ["worker"]
        else:
            # Two-node default preserves a control plane + worker split.
            roles = ["controlplane", "worker"]
    if len(roles) != node_count:
        raise ValueError("roles length must match node_count")

    # Worker that shares a tenancy with a control plane is sized 2/12, not 4/24.
    shared = "controlplane" in roles and "worker" in roles
    boots = _boot_split(node_count)
    packs: list[dict[str, int]] = []
    for role, boot in zip(roles, boots):
        target = _target_for_role(role, shared_tenancy=shared and role == "worker")
        packs.append(
            {
                "ocpus": target["ocpus"],
                "memory_gb": target["memory_gb"],
                "boot_volume_size_gb": boot,
            }
        )
    return packs


def reconcile_nodes(nodes: dict[str, Any]) -> dict[str, Any]:
    """Return a copy of nodes with fleet-target compute/boot sizes.

    Preserves all other fields (role, labels, annotations, provider_data, …).
    Does not delete nodes; if more than MAX_NODES, raises.

    Role → size:
      controlplane              → 2 OCPU / 12 GB
      worker (solo)             → 4 OCPU / 24 GB
      worker (with controlplane)→ 2 OCPU / 12 GB  (balanced HA, e.g. bwire)
    Boot volumes share MAX_BOOT_USABLE_GB evenly (4 GB free-tier buffer retained).
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
