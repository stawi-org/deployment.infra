# scripts/lib/talos_image_catalog.py
"""Decide whether the R2 Talos image catalog is complete for a fast path.

The image pipeline is expensive (omnictl download + per-account OCI/GCP
import). Day-2 work — add a worker, re-apply infra — should not rebuild
images when:

  * schematic_id matches the current schematics/cluster.yaml + Talos pin
  * every roster account already has a per-provider image handle

Schematic id formula matches sync-talos-images.yml:
  sha256(schematics/cluster.yaml bytes) + "-" + talos_version
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Any

import yaml


def schematic_id_for(schematic_path: Path, talos_version: str) -> str:
    raw = schematic_path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    ver = (talos_version or "").strip()
    if not ver:
        raise ValueError("talos_version is required")
    return f"{digest}-{ver}"


def load_yaml(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    doc = yaml.safe_load(path.read_text()) or {}
    if not isinstance(doc, dict):
        raise ValueError(f"{path}: expected mapping at root")
    return doc


def _list_accounts(accounts: dict[str, Any], key: str) -> list[str]:
    raw = accounts.get(key) or []
    if not isinstance(raw, list):
        return []
    return [str(x).strip() for x in raw if str(x).strip()]


def catalog_readiness(
    *,
    catalog: dict[str, Any],
    accounts: dict[str, Any],
    expected_schematic_id: str,
    force: bool = False,
) -> dict[str, Any]:
    """Return a readiness report.

    Keys:
      ready (bool): True → skip image pipeline
      reasons (list[str]): human-readable gaps when not ready
      missing_oracle / missing_gcp (list[str])
      schematic_match (bool)
      expected_schematic_id / stored_schematic_id
    """
    reasons: list[str] = []
    if force:
        reasons.append("force=true")

    stored_sid = str(catalog.get("schematic_id") or "").strip()
    schematic_match = bool(stored_sid) and stored_sid == expected_schematic_id
    if not catalog:
        reasons.append("catalog missing or empty")
    elif not stored_sid:
        reasons.append("catalog has no schematic_id")
    elif not schematic_match:
        reasons.append(
            f"schematic mismatch stored={stored_sid!r} expected={expected_schematic_id!r}"
        )

    formats = catalog.get("formats") if isinstance(catalog.get("formats"), dict) else {}
    contabo = formats.get("contabo") if isinstance(formats.get("contabo"), dict) else {}
    onprem = formats.get("onprem") if isinstance(formats.get("onprem"), dict) else {}
    oracle = formats.get("oracle") if isinstance(formats.get("oracle"), dict) else {}
    gcp = formats.get("gcp") if isinstance(formats.get("gcp"), dict) else {}

    contabo_accts = _list_accounts(accounts, "contabo")
    onprem_accts = _list_accounts(accounts, "onprem")
    oracle_accts = _list_accounts(accounts, "oracle")
    gcp_accts = _list_accounts(accounts, "gcp")

    if contabo_accts and not str(contabo.get("url") or "").strip():
        reasons.append("formats.contabo.url missing (contabo roster non-empty)")
    if onprem_accts and not str(onprem.get("url") or "").strip():
        reasons.append("formats.onprem.url missing (onprem roster non-empty)")

    oracle_accounts = (
        oracle.get("accounts") if isinstance(oracle.get("accounts"), dict) else {}
    )
    missing_oracle: list[str] = []
    for acct in oracle_accts:
        entry = oracle_accounts.get(acct) if isinstance(oracle_accounts.get(acct), dict) else {}
        if not str(entry.get("ocid") or "").strip():
            missing_oracle.append(acct)
    if missing_oracle:
        reasons.append(f"oracle accounts missing ocid: {', '.join(missing_oracle)}")

    gcp_accounts = gcp.get("accounts") if isinstance(gcp.get("accounts"), dict) else {}
    missing_gcp: list[str] = []
    for acct in gcp_accts:
        entry = gcp_accounts.get(acct) if isinstance(gcp_accounts.get(acct), dict) else {}
        if not str(entry.get("self_link") or "").strip():
            missing_gcp.append(acct)
    if missing_gcp:
        reasons.append(f"gcp accounts missing self_link: {', '.join(missing_gcp)}")

    ready = not reasons
    return {
        "ready": ready,
        "reasons": reasons,
        "missing_oracle": missing_oracle,
        "missing_gcp": missing_gcp,
        "schematic_match": schematic_match,
        "expected_schematic_id": expected_schematic_id,
        "stored_schematic_id": stored_sid,
        "oracle_accounts": oracle_accts,
        "gcp_accounts": gcp_accts,
    }


def evaluate_paths(
    *,
    accounts_yaml: Path,
    catalog_yaml: Path,
    schematic_path: Path,
    talos_version: str,
    force: bool = False,
) -> dict[str, Any]:
    accounts = load_yaml(accounts_yaml)
    catalog = load_yaml(catalog_yaml)
    expected = schematic_id_for(schematic_path, talos_version)
    return catalog_readiness(
        catalog=catalog,
        accounts=accounts,
        expected_schematic_id=expected,
        force=force,
    )
