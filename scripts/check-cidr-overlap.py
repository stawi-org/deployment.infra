#!/usr/bin/env python3
"""Validate that account and site CIDR blocks do not overlap."""

from __future__ import annotations

import argparse
import ipaddress
import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - CI images should provide PyYAML or install it.
    yaml = None


def read_config(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text()
        if path.suffix.lower() in {".yaml", ".yml"}:
            if yaml is None:
                raise ValueError("PyYAML is required to read YAML cluster config")
            data = yaml.safe_load(raw) or {}
        else:
            data = json.loads(raw)
    except FileNotFoundError as exc:
        raise ValueError(f"{path} does not exist") from exc
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a mapping/object")
    return data


def parse_network(name: str, cidr: str) -> tuple[str, ipaddress._BaseNetwork]:
    try:
        return name, ipaddress.ip_network(cidr, strict=True)
    except ValueError as exc:
        raise ValueError(f"{name} has invalid CIDR {cidr!r}: {exc}") from exc


def unwrap_accounts(data: dict[str, Any], context: str) -> dict[str, Any]:
    accounts = data.get("accounts", data)
    if not isinstance(accounts, dict):
        raise ValueError(f"{context} must be an object")
    return accounts


def collect_oci(path: Path) -> list[tuple[str, ipaddress._BaseNetwork]]:
    data = read_config(path)
    data = unwrap_accounts(data, "oci accounts")
    networks: list[tuple[str, ipaddress._BaseNetwork]] = []
    for account, cfg in data.items():
        cidr = cfg.get("vcn_cidr")
        if cidr:
            networks.append(parse_network(f"oci.{account}.vcn_cidr", cidr))
    return networks


def collect_onprem(path: Path) -> list[tuple[str, ipaddress._BaseNetwork]]:
    data = read_config(path)
    data = unwrap_accounts(data, "onprem accounts")
    networks: list[tuple[str, ipaddress._BaseNetwork]] = []
    for location, cfg in data.items():
        for field in ("site_ipv4_cidrs", "site_ipv6_cidrs"):
            for i, cidr in enumerate(cfg.get(field, [])):
                networks.append(parse_network(f"onprem.{location}.{field}[{i}]", cidr))
    return networks


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--oci", type=Path, help="Path to OCI accounts YAML/JSON.")
    parser.add_argument("--onprem", type=Path, help="Path to on-prem accounts YAML/JSON.")
    args = parser.parse_args()

    networks: list[tuple[str, ipaddress._BaseNetwork]] = []
    try:
        if args.oci:
            networks.extend(collect_oci(args.oci))
        if args.onprem:
            networks.extend(collect_onprem(args.onprem))
    except ValueError as exc:
        print(f"CIDR validation error: {exc}", file=sys.stderr)
        return 2

    errors: list[str] = []
    for i, (left_name, left_net) in enumerate(networks):
        for right_name, right_net in networks[i + 1 :]:
            if left_net.version == right_net.version and left_net.overlaps(right_net):
                errors.append(f"{left_name} {left_net} overlaps {right_name} {right_net}")

    if errors:
        for err in errors:
            print(f"CIDR overlap: {err}", file=sys.stderr)
        return 1

    print(f"CIDR validation passed for {len(networks)} network(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
