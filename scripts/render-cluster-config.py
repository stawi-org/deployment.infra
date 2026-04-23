#!/usr/bin/env python3
"""Render cluster inventory from R2/S3 YAML config files or a config directory."""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
import sys
from pathlib import Path
from typing import Any

try:
    import yaml
except ImportError:  # pragma: no cover - CI images should provide PyYAML or install it.
    yaml = None


DEFAULT_VCN_CIDR = "10.200.0.0/16"


def ensure_map(value: Any, context: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ValueError(f"{context} must be an object")
    return value


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
        "onprem": {"accounts": {}},
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
            accounts = contabo.get("accounts")
            if accounts is None:
                raise ValueError(f"{file}: contabo.accounts is required")
            merge_section("contabo", "accounts", accounts, file)
        if "oci" in data:
            oci = data["oci"] or {}
            if not isinstance(oci, dict):
                raise ValueError(f"{file}: oci must be an object")
            accounts = oci.get("accounts") or {}
            retained = oci.get("retained_accounts") or {}
            if not accounts and not retained:
                raise ValueError(f"{file}: oci.accounts or oci.retained_accounts is required")
            merge_section("oci", "accounts", accounts, file)
            merge_section("oci", "retained_accounts", retained, file)
        if "onprem" in data:
            onprem = data["onprem"] or {}
            if not isinstance(onprem, dict):
                raise ValueError(f"{file}: onprem must be an object")
            accounts = onprem.get("accounts")
            if accounts is None:
                raise ValueError(f"{file}: onprem.accounts is required")
            merge_section("onprem", "accounts", accounts, file)

    return merged


def dump(path: Path, data: Any) -> None:
    path.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")


def normalize_oci_account(name: str, raw: dict[str, Any]) -> tuple[dict[str, Any], dict[str, str]]:
    auth = ensure_map(raw.get("auth"), f"OCI account {name}: auth")

    tenancy = raw.get("tenancy_ocid")
    region = raw.get("region")
    vcn_cidr = raw.get("vcn_cidr", DEFAULT_VCN_CIDR)
    nodes = raw.get("nodes")
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
    if not isinstance(nodes, dict):
        raise ValueError(f"OCI account {name}: nodes must be an object")
    labels = ensure_map(raw.get("labels"), f"OCI account {name}: labels")
    annotations = ensure_map(raw.get("annotations"), f"OCI account {name}: annotations")

    normalized_nodes: dict[str, Any] = {}
    for node_name, node_raw in nodes.items():
        if not isinstance(node_raw, dict):
            raise ValueError(f"OCI node {name}/{node_name}: node value must be an object")
        node = dict(node_raw)
        node["role"] = node.get("role", "worker")
        node["labels"] = ensure_map(node.get("labels"), f"OCI node {name}/{node_name}: labels")
        node["annotations"] = ensure_map(node.get("annotations"), f"OCI node {name}/{node_name}: annotations")
        normalized_nodes[node_name] = node

    tf_account = {
        "tenancy_ocid": tenancy,
        "compartment_ocid": raw.get("compartment_ocid") or tenancy,
        "region": region,
        "vcn_cidr": vcn_cidr,
        "enable_ipv6": raw.get("enable_ipv6", True),
        "bastion_client_cidr_block_allow_list": raw.get("bastion_client_cidr_block_allow_list", ["0.0.0.0/0"]),
        "labels": labels,
        "annotations": annotations,
        "nodes": normalized_nodes,
    }
    auth_account = {
        "profile": name,
        "tenancy_ocid": tenancy,
        "region": region,
        "domain_base_url": domain,
        "oidc_client_identifier": client,
    }
    return tf_account, auth_account


def render_inventory_file(file: Path, retained_profiles: set[str]) -> dict[str, Any]:
    data = load_config(file)
    rendered: dict[str, Any] = {
        "contabo": {},
        "oci_active": {},
        "oci_retained": {},
        "oci_auth": [],
        "onprem": {},
    }

    if "contabo" in data:
        contabo = data["contabo"] or {}
        if not isinstance(contabo, dict):
            raise ValueError(f"{file}: contabo must be an object")
        rendered["contabo"] = contabo_from_config(file)

    if "oci" in data:
        oci = data["oci"] or {}
        if not isinstance(oci, dict):
            raise ValueError(f"{file}: oci must be an object")
        active, retained, auth = oci_from_map(
            {
                "accounts": oci.get("accounts", {}),
                "retained_accounts": oci.get("retained_accounts", {}),
            },
            retained_profiles,
        )
        rendered["oci_active"] = active
        rendered["oci_retained"] = retained
        rendered["oci_auth"] = auth

    if "onprem" in data:
        onprem = data["onprem"] or {}
        if not isinstance(onprem, dict):
            raise ValueError(f"{file}: onprem must be an object")
        rendered["onprem"] = onprem_from_map(onprem)

    if not any(rendered[key] for key in ("contabo", "oci_active", "oci_retained", "oci_auth", "onprem")):
        raise ValueError(f"{file}: no supported inventory sections found")

    return rendered


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
    else:
        raise ValueError("Contabo config must contain a contabo.accounts map")
    if not isinstance(accounts, dict):
        raise ValueError("Contabo config must contain an accounts map")

    rendered: dict[str, Any] = {}
    seen_nodes: set[str] = set()

    for account_name, raw in accounts.items():
        if not isinstance(raw, dict):
            raise ValueError(f"Contabo account {account_name}: account value must be an object")
        auth = ensure_map(raw.get("auth"), f"Contabo account {account_name}: auth")
        labels = ensure_map(raw.get("labels"), f"Contabo account {account_name}: labels")
        annotations = ensure_map(raw.get("annotations"), f"Contabo account {account_name}: annotations")

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

        nodes = raw.get("nodes")
        if nodes is None:
            raise ValueError(f"Contabo account {account_name}: nodes is required")
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
            "labels": labels,
            "annotations": annotations,
            "nodes": rendered_nodes,
        }

    return rendered


def oci_from_map(data: dict[str, Any], retained_profiles: set[str]) -> tuple[dict[str, Any], dict[str, Any], list[dict[str, str]]]:
    accounts = data.get("accounts") or {}
    retained_accounts = data.get("retained_accounts") or {}
    if not accounts and not retained_accounts:
        raise ValueError("OCI config must contain accounts or retained_accounts maps")

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
    accounts = data.get("accounts")
    if accounts is None:
        raise ValueError("onprem.accounts is required")
    if not isinstance(accounts, dict):
        raise ValueError("accounts must be an object")
    normalized: dict[str, Any] = {}
    for account_name, raw in accounts.items():
        if not isinstance(raw, dict):
            raise ValueError(f"On-prem account {account_name}: account value must be an object")
        account_region = raw.get("region")
        nodes = raw.get("nodes")
        if nodes is None:
            raise ValueError(f"On-prem account {account_name}: nodes is required")
        if not isinstance(nodes, dict):
            raise ValueError(f"On-prem account {account_name}: nodes must be an object")
        normalized_nodes: dict[str, Any] = {}
        for node_name, node_raw in nodes.items():
            if not isinstance(node_raw, dict):
                raise ValueError(f"On-prem node {account_name}/{node_name}: node value must be an object")
            node = dict(node_raw)
            node["region"] = node.get("region", account_region)
            node["role"] = node.get("role", "worker")
            node["labels"] = ensure_map(node.get("labels"), f"On-prem node {account_name}/{node_name}: labels")
            node["annotations"] = ensure_map(node.get("annotations"), f"On-prem node {account_name}/{node_name}: annotations")
            normalized_nodes[node_name] = node
        normalized[account_name] = {**raw, "nodes": normalized_nodes}
    return normalized


def render_onprem(args: argparse.Namespace) -> int:
    try:
        if not args.input:
            raise ValueError("input path is required")
        data = load_inventory_source(args.input)
    except ValueError as exc:
        print(f"On-prem config error: {exc}", file=sys.stderr)
        return 2
    try:
        accounts = onprem_from_map(data)
    except ValueError as exc:
        print(f"On-prem config error: {exc}", file=sys.stderr)
        return 2
    dump(args.out, accounts)
    print(f"Rendered on-prem config: accounts={len(accounts)}")
    return 0


def render_cluster(args: argparse.Namespace) -> int:
    try:
        if not args.input:
            raise ValueError("input path is required")
        files = inventory_files(args.input)
    except ValueError as exc:
        print(f"Cluster config error: {exc}", file=sys.stderr)
        return 2

    try:
        retained_profiles = {
            item.strip()
            for item in (args.retained_profiles or "").split(",")
            if item.strip()
        }
        rendered_parts = []
        if files:
            with ThreadPoolExecutor(max_workers=min(32, len(files))) as executor:
                rendered_parts = list(executor.map(lambda f: render_inventory_file(f, retained_profiles), files))
    except ValueError as exc:
        print(f"Cluster config error: {exc}", file=sys.stderr)
        return 2

    contabo_accounts: dict[str, Any] = {}
    oci_active: dict[str, Any] = {}
    oci_retained: dict[str, Any] = {}
    oci_auth: list[dict[str, str]] = []
    onprem_accounts: dict[str, Any] = {}

    for part in rendered_parts:
        for account_name, account in part["contabo"].items():
            if account_name in contabo_accounts:
                print(f"Cluster config error: duplicate Contabo account {account_name}", file=sys.stderr)
                return 2
            contabo_accounts[account_name] = account
        for account_name, account in part["oci_active"].items():
            if account_name in oci_active or account_name in oci_retained:
                print(f"Cluster config error: duplicate OCI account {account_name}", file=sys.stderr)
                return 2
            oci_active[account_name] = account
        for account_name, account in part["oci_retained"].items():
            if account_name in oci_active or account_name in oci_retained:
                print(f"Cluster config error: duplicate OCI retained account {account_name}", file=sys.stderr)
                return 2
            oci_retained[account_name] = account
        oci_auth.extend(part["oci_auth"])
        for account_name, account in part["onprem"].items():
            if account_name in onprem_accounts:
                print(f"Cluster config error: duplicate on-prem account {account_name}", file=sys.stderr)
                return 2
            onprem_accounts[account_name] = account

    dump(args.out_contabo_accounts, contabo_accounts)
    dump(args.out_oci_accounts, oci_active)
    dump(args.out_retained_oci_accounts, oci_retained)
    dump(args.out_oci_auth_accounts, oci_auth)
    dump(args.out_onprem_accounts, onprem_accounts)
    print(
        "Rendered cluster config: "
        f"contabo_accounts={len(contabo_accounts)} "
        f"oci_accounts={len(oci_active)} "
        f"oci_retained={len(oci_retained)} "
        f"onprem_accounts={len(onprem_accounts)}"
    )
    return 0


def inventory_files(path: Path) -> list[Path]:
    if path.is_file():
        return [path]
    if not path.is_dir():
        raise ValueError(f"{path} does not exist or is not a directory")
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
    return files


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
    cluster.add_argument("--out-onprem-accounts", type=Path, required=True)

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
