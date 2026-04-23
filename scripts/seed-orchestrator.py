#!/usr/bin/env python3
"""
Seeds R2 production/inventory/ for the first apply.

Inputs read from R2:
  production/config/contabo/<acct>.yaml   operator-authored contabo inventory + auth
  production/config/oci/<acct>.yaml       operator-authored oracle inventory + auth pointers
  production/config/onprem/<loc>.yaml     operator-authored on-prem inventory

For each account listed in tofu/shared/accounts.yaml, renders the corresponding
production/inventory/<provider>/<acct>/ files:
  - nodes.yaml (plaintext, operator intent)
  - auth.yaml  (contabo = age-encrypted, oracle = plaintext, onprem = skipped)
  - state.yaml (provider-discovered instance IDs/IPs, or empty)

machine-configs.yaml and talos-state.yaml are left unwritten; layer 03 creates
them on first apply.

Required env:
  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, R2_ENDPOINT_URL
  SOPS_AGE_KEY, SOPS_AGE_RECIPIENTS  (for encrypting contabo auth.yaml)
"""

from __future__ import annotations

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import yaml

OUTDIR = pathlib.Path("/tmp/seed-output")
R2_BUCKET = "cluster-tofu-state"
R2_CONFIG_PREFIX = "production/config"
R2_INVENTORY_PREFIX = "production/inventory"

here = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(here / "lib"))
from inventory_yaml import render_nodes_yaml, render_state_yaml  # noqa: E402


def log(msg: str) -> None:
    print(f"[seed-orchestrator] {msg}", flush=True)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    log("$ " + " ".join(cmd))
    return subprocess.run(cmd, check=True, **kw)


def r2_endpoint() -> str:
    ep = os.environ.get("R2_ENDPOINT_URL")
    if not ep:
        sys.exit("R2_ENDPOINT_URL required")
    return ep


def fetch_config_tree(dst: pathlib.Path) -> None:
    dst.mkdir(parents=True, exist_ok=True)
    run([
        "aws", "s3", "sync",
        f"s3://{R2_BUCKET}/{R2_CONFIG_PREFIX}/", str(dst),
        "--endpoint-url", r2_endpoint(), "--region", "us-east-1",
    ])


def write_yaml_file(path: pathlib.Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w") as fh:
        yaml.safe_dump(payload, fh, sort_keys=True, default_flow_style=False, width=100)


def encrypt_in_place(path: pathlib.Path) -> None:
    recipients = os.environ.get("SOPS_AGE_RECIPIENTS")
    if not recipients:
        sys.exit("SOPS_AGE_RECIPIENTS required to encrypt auth.yaml")
    tmp_out = path.with_suffix(path.suffix + ".age")
    env = dict(os.environ)
    env["SOPS_AGE_RECIPIENTS"] = recipients
    with tmp_out.open("wb") as out_fh:
        run([
            "sops", "-e",
            "--input-type", "yaml", "--output-type", "yaml",
            "--encrypted-regex", ".",
            str(path),
        ], stdout=out_fh, env=env)
    shutil.move(str(tmp_out), str(path))


def contabo_list_instances(auth: dict) -> list[dict]:
    env = dict(os.environ)
    env["CONTABO_CLIENT_ID"] = auth["oauth2_client_id"]
    env["CONTABO_CLIENT_SECRET"] = auth["oauth2_client_secret"]
    env["CONTABO_API_USER"] = auth["oauth2_user"]
    env["CONTABO_API_PASSWORD"] = auth["oauth2_pass"]
    result = subprocess.run(
        [str(here / "contabo-list-instances.sh")],
        check=True, capture_output=True, env=env,
    )
    payload = json.loads(result.stdout.decode("utf-8"))
    return payload.get("data", payload.get("instances", []))


def oci_list_instances(compartment_ocid: str) -> list[dict]:
    env = dict(os.environ)
    env["OCI_COMPARTMENT_OCID"] = compartment_ocid
    result = subprocess.run(
        [str(here / "oci-list-instances.sh")],
        check=True, capture_output=True, env=env,
    )
    payload = json.loads(result.stdout.decode("utf-8"))
    return payload.get("data", payload)


def seed_contabo(acct: str, cfg: dict, bootstrap: dict, out: pathlib.Path) -> None:
    log(f"contabo/{acct}: seeding")
    account_data = cfg["contabo"]["accounts"][acct]
    auth = account_data["auth"]
    nodes = account_data.get("nodes", {})
    labels = account_data.get("labels", {})
    annotations = account_data.get("annotations", {})

    acct_out = out / "contabo" / acct
    acct_out.mkdir(parents=True, exist_ok=True)

    (acct_out / "nodes.yaml").write_text(
        render_nodes_yaml(
            provider="contabo",
            account=acct,
            account_meta={"labels": labels, "annotations": annotations},
            nodes=nodes,
        )
    )

    auth_payload = {"provider": "contabo", "account": acct, "auth": auth}
    write_yaml_file(acct_out / "auth.yaml", auth_payload)
    encrypt_in_place(acct_out / "auth.yaml")

    try:
        instances = contabo_list_instances(auth)
    except subprocess.CalledProcessError as e:
        log(f"contabo/{acct}: list-instances failed ({e}); falling back to bootstrap")
        instances = []

    by_name: dict[str, list[dict]] = {}
    for inst in instances:
        by_name.setdefault(inst.get("displayName"), []).append(inst)

    resolved: dict[str, dict] = {}
    for node_key, node_decl in nodes.items():
        matches = by_name.get(node_key, [])
        if matches:
            first = matches[0]
            ipc = first.get("ipConfig") or {}
            resolved[node_key] = {
                "contabo_instance_id": str(first["instanceId"]),
                "product_id": node_decl.get("product_id"),
                "region": node_decl.get("region"),
                "ipv4": (ipc.get("v4") or [{}])[0].get("ip"),
                "ipv6": (ipc.get("v6") or [{}])[0].get("ip"),
                "status": "running",
            }
            if len(matches) > 1:
                log(f"WARN contabo/{acct}/{node_key}: multiple matches; using first")
            continue
        fallback = (
            bootstrap.get("contabo", {}).get(acct, {}).get(node_key)
        )
        if fallback:
            log(f"contabo/{acct}/{node_key}: no live match; using bootstrap")
            resolved[node_key] = {
                "contabo_instance_id": fallback["contabo_instance_id"],
                "product_id": node_decl.get("product_id"),
                "region": node_decl.get("region"),
                "status": "unknown",
            }
        else:
            log(f"contabo/{acct}/{node_key}: no live match AND no bootstrap — tofu will create")

    (acct_out / "state.yaml").write_text(
        render_state_yaml(provider="contabo", account=acct, node_provider_data=resolved)
    )


def seed_oracle(acct: str, cfg: dict, out: pathlib.Path) -> None:
    log(f"oracle/{acct}: seeding")
    account_data = cfg["oci"]["accounts"][acct]
    nodes = account_data.get("nodes", {})

    acct_out = out / "oracle" / acct
    acct_out.mkdir(parents=True, exist_ok=True)

    account_meta = {
        "labels": account_data.get("labels", {}),
        "annotations": account_data.get("annotations", {}),
        "tenancy_ocid": account_data["tenancy_ocid"],
        "compartment_ocid": account_data["compartment_ocid"],
        "region": account_data["region"],
        "vcn_cidr": account_data["vcn_cidr"],
        "enable_ipv6": account_data.get("enable_ipv6", True),
        "bastion_client_cidr_block_allow_list":
            account_data.get("bastion_client_cidr_block_allow_list", ["0.0.0.0/0"]),
    }
    (acct_out / "nodes.yaml").write_text(
        render_nodes_yaml(
            provider="oracle", account=acct, account_meta=account_meta, nodes=nodes,
        )
    )

    auth_payload = {
        "provider": "oracle",
        "account": acct,
        "auth": {
            "tenancy_ocid": account_data["tenancy_ocid"],
            "compartment_ocid": account_data["compartment_ocid"],
            "region": account_data["region"],
            "config_file_profile": acct,
            "auth_method": "SecurityToken",
        },
    }
    write_yaml_file(acct_out / "auth.yaml", auth_payload)

    resolved: dict[str, dict] = {}
    try:
        instances = oci_list_instances(account_data["compartment_ocid"])
        by_name: dict[str, list[dict]] = {}
        for inst in instances:
            by_name.setdefault(
                inst.get("display-name") or inst.get("displayName"), []
            ).append(inst)
        for node_key in nodes:
            matches = by_name.get(node_key, [])
            if len(matches) == 1:
                resolved[node_key] = {
                    "oci_instance_ocid": matches[0]["id"],
                    "shape": matches[0].get("shape"),
                    "region": account_data["region"],
                    "status": "running",
                }
    except (subprocess.CalledProcessError, OSError) as e:
        log(f"oracle/{acct}: list-instances skipped ({e}); state.yaml will be empty")

    (acct_out / "state.yaml").write_text(
        render_state_yaml(provider="oracle", account=acct, node_provider_data=resolved)
    )


def seed_onprem(loc: str, cfg: dict, out: pathlib.Path) -> None:
    log(f"onprem/{loc}: seeding")
    account_data = cfg["onprem"]["accounts"][loc]
    nodes = account_data.get("nodes", {})
    acct_out = out / "onprem" / loc
    acct_out.mkdir(parents=True, exist_ok=True)

    account_meta = {
        "description": account_data.get("description", ""),
        "region": account_data.get("region", ""),
        "labels": account_data.get("labels", {}),
        "annotations": account_data.get("annotations", {}),
    }
    (acct_out / "nodes.yaml").write_text(
        render_nodes_yaml(
            provider="onprem", account=loc, account_meta=account_meta, nodes=nodes,
        )
    )
    (acct_out / "state.yaml").write_text(
        render_state_yaml(provider="onprem", account=loc, node_provider_data={})
    )


def main() -> None:
    OUTDIR.mkdir(parents=True, exist_ok=True)

    manifest = yaml.safe_load(open("tofu/shared/accounts.yaml"))
    bootstrap_path = pathlib.Path("tofu/shared/bootstrap/contabo-instance-ids.yaml")
    bootstrap = yaml.safe_load(bootstrap_path.read_text()) if bootstrap_path.exists() else {}

    with tempfile.TemporaryDirectory(prefix="seed-config-") as td:
        config_dir = pathlib.Path(td)
        fetch_config_tree(config_dir)

        for acct in manifest.get("contabo", []):
            cfg_path = config_dir / "contabo" / f"{acct}.yaml"
            if not cfg_path.exists():
                log(f"WARN: contabo/{acct} missing in R2 config tree; skipping")
                continue
            cfg = yaml.safe_load(cfg_path.read_text())
            seed_contabo(acct, cfg, bootstrap, OUTDIR)

        for acct in manifest.get("oracle", []):
            cfg_path = config_dir / "oci" / f"{acct}.yaml"
            if not cfg_path.exists():
                log(f"WARN: oracle/{acct} missing in R2 config tree; skipping")
                continue
            cfg = yaml.safe_load(cfg_path.read_text())
            seed_oracle(acct, cfg, OUTDIR)

        for loc in manifest.get("onprem", []):
            cfg_path = config_dir / "onprem" / f"{loc}.yaml"
            if not cfg_path.exists():
                log(f"WARN: onprem/{loc} missing in R2 config tree; skipping")
                continue
            cfg = yaml.safe_load(cfg_path.read_text())
            seed_onprem(loc, cfg, OUTDIR)

    run([
        "aws", "s3", "sync", str(OUTDIR),
        f"s3://{R2_BUCKET}/{R2_INVENTORY_PREFIX}/",
        "--endpoint-url", r2_endpoint(), "--region", "us-east-1",
    ])
    log("done")


if __name__ == "__main__":
    main()
