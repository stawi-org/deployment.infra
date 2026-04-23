#!/usr/bin/env python3
"""Render cluster inventory from R2/S3 YAML config files or a config directory."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - CI images should provide PyYAML or install it.
    yaml = None


DEFAULT_VCN_CIDR = "10.200.0.0/16"
DEFAULT_WORKERS = {"wk-1": {"shape": "VM.Standard.A1.Flex", "ocpus": 4, "memory_gb": 24}}


def load_config(path: Path) -> dict[str, Any]:
    try:
        raw = path.read_text()
        if path.suffix.lower() in {".yaml", ".yml"}:
            if yaml is None:
                raise ValueError("PyYAML is required to read YAML cluster config")
            data = yaml.safe_load(raw) or {}
        else:
            data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"{path} is not valid JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"{path} must contain a mapping/object")
    return data


def load_inventory_source(path: Path) -> dict[str, Any]:
    if path.is_file():
        return load_config(path)
    if not path.is_dir():
        raise ValueError(f"{path} does not exist or is not a directory")

    merged: dict[str, Any] = {
        "contabo": {"accounts": {}},
        "oci": {"accounts": {}, "retained_accounts": {}},
        "onprem": {"locations": {}},
    }

    files = sorted(
        [
            candidate
            for candidate in path.rglob("*")
            if candidate.is_file() and candidate.suffix.lower() in {".yaml", ".yml"}
        ],
        key=lambda candidate: str(candidate.relative_to(path)),
    )
    if not files:
        raise ValueError(f"{path} does not contain any YAML inventory files")

    def merge_section(section: str, key: str, value: dict[str, Any], source: Path) -> None:
        target = merged[section][key]
        if not isinstance(value, dict):
            raise ValueError(f"{source}: {section}.{key} must be an object")
        for name, item in value.items():
            if name in target:
                raise ValueError(f"{source}: duplicate {section}.{key[:-1]} {name}")
            target[name] = item

    for file in files:
        data = load_config(file)
        if "contabo" in data:
            contabo = data["contabo"] or {}
            if not isinstance(contabo, dict):
                raise ValueError(f"{file}: contabo must be an object")
            accounts = contabo.get("accounts") or contabo.get("contabo_accounts") or {}
            merge_section("contabo", "accounts", accounts, file)
        if "oci" in data:
            oci = data["oci"] or {}
            if not isinstance(oci, dict):
                raise ValueError(f"{file}: oci must be an object")
            accounts = oci.get("accounts") or oci.get("oci_accounts") or {}
            retained = oci.get("retained_accounts") or oci.get("retained_oci_accounts") or {}
            merge_section("oci", "accounts", accounts, file)
            merge_section("oci", "retained_accounts", retained, file)
        if "onprem" in data:
            onprem = data["onprem"] or {}
            if not isinstance(onprem, dict):
                raise ValueError(f"{file}: onprem must be an object")
            locations = onprem.get("locations") or onprem.get("onprem_locations") or {}
            merge_section("onprem", "locations", locations, file)

    return merged


def dump(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")


def normalize_oci_account(name: str, raw: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    auth = raw.get("auth") or {}
    if not isinstance(auth, dict):
        raise ValueError(f"OCI account {name}: auth must be an object")

    tenancy = raw.get("tenancy_ocid")
    region = raw.get("region")
    vcn_cidr = raw.get("vcn_cidr", DEFAULT_VCN_CIDR)
    workers = raw.get("workers", DEFAULT_WORKERS)
    domain = auth.get("domain_base_url") or raw.get("domain_base_url") or raw.get("oci_domain_base_url")
    client = auth.get("oidc_client_identifier") or raw.get("oidc_client_identifier")

    missing = [
        field
        for field, value in {
            "tenancy_ocid": tenancy,
            "region": region,
            "domain_base_url": domain,
            "oidc_client_identifier": client,
        }.items()
        if not value
    ]
    if missing:
        raise ValueError(f"OCI account {name}: missing required field(s): {', '.join(missing)}")
    if not isinstance(workers, dict):
        raise ValueError(f"OCI account {name}: workers must be an object")

    tf_account = {
        "tenancy_ocid": tenancy,
        "compartment_ocid": raw.get("compartment_ocid") or tenancy,
        "region": region,
        "vcn_cidr": vcn_cidr,
        "enable_ipv6": raw.get("enable_ipv6", True),
        "bastion_client_cidr_block_allow_list": raw.get("bastion_client_cidr_block_allow_list", ["0.0.0.0/0"]),
        "labels": raw.get("labels", {}),
        "annotations": raw.get("annotations", {}),
        "workers": workers,
    }
    auth_account = {
        "profile": name,
        "tenancy_ocid": tenancy,
        "region": region,
        "domain_base_url": domain,
        "oidc_client_identifier": client,
    }
    return tf_account, auth_account


def normalize_contabo_node(account_name: str, node_name: str, raw: dict[str, Any]) -> dict[str, Any]:
    role = raw.get("role", "controlplane")
    product_id = raw.get("product_id")
    region = raw.get("region", "EU")
    labels = raw.get("labels", {})
    annotations = raw.get("annotations", {})

    missing = [field for field, value in {"product_id": product_id}.items() if not value]
    if missing:
        raise ValueError(f"Contabo node {account_name}/{node_name}: missing required field(s): {', '.join(missing)}")
    if role not in {"controlplane", "worker"}:
        raise ValueError(f"Contabo node {account_name}/{node_name}: role must be 'controlplane' or 'worker'")
    if not isinstance(labels, dict) or not isinstance(annotations, dict):
        raise ValueError(f"Contabo node {account_name}/{node_name}: labels and annotations must be objects")

    return {
        "role": role,
        "product_id": product_id,
        "region": region,
        "labels": labels,
        "annotations": annotations,
    }


def contabo_from_config(path: Path) -> dict[str, Any]:
    data = load_inventory_source(path)
    contabo = data.get("contabo") or {}
    if "accounts" in contabo:
        accounts = contabo["accounts"]
    elif "contabo_accounts" in contabo:
        accounts = contabo["contabo_accounts"]
    else:
        accounts = contabo
    if not isinstance(accounts, dict):
        raise ValueError("Contabo config must contain an accounts map")

    rendered: dict[str, Any] = {}
    seen_nodes: set[str] = set()

    for account_name, raw in accounts.items():
        if not isinstance(raw, dict):
            raise ValueError(f"Contabo account {account_name}: account value must be an object")
        auth = raw.get("auth") or {}
        if not isinstance(auth, dict):
            raise ValueError(f"Contabo account {account_name}: auth must be an object")

        missing = [
            field
            for field, value in {
                "oauth2_client_id": auth.get("oauth2_client_id"),
                "oauth2_client_secret": auth.get("oauth2_client_secret"),
                "oauth2_user": auth.get("oauth2_user"),
                "oauth2_pass": auth.get("oauth2_pass"),
            }.items()
            if not value
        ]
        if missing:
            raise ValueError(f"Contabo account {account_name}: missing required field(s): {', '.join(missing)}")

        nodes = raw.get("nodes") or raw.get("controlplane_nodes") or {}
        if not isinstance(nodes, dict):
            raise ValueError(f"Contabo account {account_name}: nodes must be an object")

        rendered_nodes: dict[str, Any] = {}
        for node_name, node_raw in nodes.items():
            if not isinstance(node_raw, dict):
                raise ValueError(f"Contabo node {account_name}/{node_name}: node value must be an object")
            if node_name in seen_nodes:
                raise ValueError(f"Contabo node {node_name} is duplicated across accounts")
            seen_nodes.add(node_name)
            rendered_nodes[node_name] = normalize_contabo_node(account_name, node_name, node_raw)

        rendered[account_name] = {
            "auth": auth,
            "labels": raw.get("labels", {}),
            "annotations": raw.get("annotations", {}),
            "nodes": rendered_nodes,
        }

    return rendered


def oci_from_map(data: dict[str, Any], retained_profiles: set[str]) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, str]]]:
    if "accounts" in data:
        accounts = data["accounts"]
    elif "oci_accounts" in data:
        accounts = data["oci_accounts"]
    else:
        accounts = {
            key: value
            for key, value in data.items()
            if key not in {"retained_accounts", "retained_oci_accounts"}
        }
    retained_accounts = data.get("retained_accounts") or data.get("retained_oci_accounts") or {}

    if not isinstance(accounts, dict) or not isinstance(retained_accounts, dict):
        raise ValueError("OCI config must contain account maps")

    active_tf: dict[str, Any] = {}
    retained_tf: dict[str, Any] = {}
    auth_accounts: list[dict[str, str]] = []

    for name, raw in accounts.items():
        if not isinstance(raw, dict):
            raise ValueError(f"OCI account {name}: account value must be an object")
        tf_account, auth_account = normalize_oci_account(name, raw)
        auth_accounts.append(auth_account)
        if raw.get("retained", False) or name in retained_profiles:
            retained_tf[name] = tf_account
        else:
            active_tf[name] = tf_account

    for name, raw in retained_accounts.items():
        if not isinstance(raw, dict):
            raise ValueError(f"OCI retained account {name}: account value must be an object")
        tf_account, auth_account = normalize_oci_account(name, raw)
        retained_tf[name] = tf_account
        auth_accounts.append(auth_account)

    return active_tf, retained_tf, auth_accounts


def oci_from_config(path: Path, retained_profiles: set[str]) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, str]]]:
    data = load_inventory_source(path)
    return oci_from_map(data, retained_profiles)

def render_oci(args: argparse.Namespace) -> int:
    retained_profiles = {
        item.strip()
        for item in (args.retained_profiles or "").split(",")
        if item.strip()
    }
    if not args.input or not args.input.exists():
        print("OCI config error: input file is required", file=sys.stderr)
        return 2
    try:
        active, retained, auth = oci_from_config(args.input, retained_profiles)
    except ValueError as exc:
        print(f"OCI config error: {exc}", file=sys.stderr)
        return 2

    dump(args.out_accounts, active)
    dump(args.out_retained_accounts, retained)
    dump(args.out_auth, auth)
    print(f"Rendered OCI config: active={len(active)} retained={len(retained)} auth_profiles={len(auth)}")
    return 0


def onprem_from_map(data: dict[str, Any]) -> dict[str, Any]:
    locations = data.get("locations") or data.get("onprem_locations") or data
    if not isinstance(locations, dict):
        raise ValueError("locations must be an object")
    return locations


def render_onprem(args: argparse.Namespace) -> int:
    try:
        if not args.input:
            raise ValueError("input path is required")
        data = load_inventory_source(args.input)
    except ValueError as exc:
        print(f"On-prem config error: {exc}", file=sys.stderr)
        return 2
    try:
        locations = onprem_from_map(data)
    except ValueError as exc:
        print(f"On-prem config error: {exc}", file=sys.stderr)
        return 2
    dump(args.out, locations)
    print(f"Rendered on-prem config: locations={len(locations)}")
    return 0


def render_cluster(args: argparse.Namespace) -> int:
    try:
        if not args.input:
            raise ValueError("input path is required")
        data = load_inventory_source(args.input)
    except ValueError as exc:
        print(f"Cluster config error: {exc}", file=sys.stderr)
        return 2

    contabo_data = data.get("contabo") or {}
    oci_data = data.get("oci") or {}
    onprem_data = data.get("onprem") or {}

    try:
        contabo_accounts = contabo_from_config(args.input) if contabo_data else {}
        oci_active, oci_retained, oci_auth = oci_from_map(oci_data, {
            item.strip()
            for item in (args.retained_profiles or "").split(",")
            if item.strip()
        }) if oci_data else ({}, {}, [])
        onprem_locations = onprem_from_map(onprem_data) if onprem_data else {}
    except ValueError as exc:
        print(f"Cluster config error: {exc}", file=sys.stderr)
        return 2

    dump(args.out_contabo_accounts, contabo_accounts)
    dump(args.out_oci_accounts, oci_active)
    dump(args.out_retained_oci_accounts, oci_retained)
    dump(args.out_oci_auth_accounts, oci_auth)
    dump(args.out_onprem_locations, onprem_locations)
    print(
        "Rendered cluster config: "
        f"contabo_accounts={len(contabo_accounts)} "
        f"oci_accounts={len(oci_active)} "
        f"oci_retained={len(oci_retained)} "
        f"onprem_locations={len(onprem_locations)}"
    )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    oci = sub.add_parser("oci")
    oci.add_argument("--input", type=Path)
    oci.add_argument("--retained-profiles", default="")
    oci.add_argument("--out-accounts", type=Path, required=True)
    oci.add_argument("--out-retained-accounts", type=Path, required=True)
    oci.add_argument("--out-auth", type=Path, required=True)

    onprem = sub.add_parser("onprem")
    onprem.add_argument("--input", type=Path)
    onprem.add_argument("--out", type=Path, required=True)

    cluster = sub.add_parser("cluster")
    cluster.add_argument("--input", type=Path, required=True)
    cluster.add_argument("--retained-profiles", default="")
    cluster.add_argument("--out-contabo-accounts", type=Path, required=True)
    cluster.add_argument("--out-oci-accounts", type=Path, required=True)
    cluster.add_argument("--out-retained-oci-accounts", type=Path, required=True)
    cluster.add_argument("--out-oci-auth-accounts", type=Path, required=True)
    cluster.add_argument("--out-onprem-locations", type=Path, required=True)

    args = parser.parse_args()
    if args.command == "oci":
        return render_oci(args)
    if args.command == "onprem":
        return render_onprem(args)
    if args.command == "cluster":
        return render_cluster(args)
    raise AssertionError(args.command)


if __name__ == "__main__":
    raise SystemExit(main())
