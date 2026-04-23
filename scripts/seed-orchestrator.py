#!/usr/bin/env python3
"""Reads accounts.yaml, invokes seed-inventory.sh per provider+account."""
import os, subprocess, sys, yaml

manifest = yaml.safe_load(open("tofu/shared/accounts.yaml"))
outdir = "/tmp/seed-output"

# Load existing provider config YAMLs from providers/config/ — these are
# the operator-authored declarations committed to the repo (contain node
# lists, shapes, etc). Pass through.
for acct in manifest.get("contabo", []):
    cfg_path = f"providers/config/contabo/{acct}.yaml"
    if not os.path.exists(cfg_path):
        print(f"WARN: no provider config for contabo/{acct}; skipping")
        continue
    cfg = yaml.safe_load(open(cfg_path))
    nodes = list(cfg["contabo"]["accounts"][acct]["nodes"].keys())
    args = [
        "scripts/seed-inventory.sh",
        "--output-dir", outdir,
        "--bootstrap", "tofu/shared/bootstrap/contabo-instance-ids.yaml",
        "--contabo-account", acct,
        "--contabo-list-cmd", "scripts/contabo-list-instances.sh",
    ]
    for n in nodes:
        args += ["--contabo-node", n]
    subprocess.check_call(args)

for acct in manifest.get("oracle", []):
    cfg_path = f"providers/config/oci/{acct}.yaml"
    if not os.path.exists(cfg_path):
        print(f"WARN: no provider config for oracle/{acct}; skipping")
        continue
    cfg = yaml.safe_load(open(cfg_path))
    nodes = list(cfg["oci"]["accounts"][acct]["nodes"].keys())
    args = [
        "scripts/seed-inventory.sh",
        "--output-dir", outdir,
        "--oci-account", acct,
        "--oci-list-cmd", "scripts/oci-list-instances.sh",
    ]
    for n in nodes:
        args += ["--oci-node", n]
    os.environ["OCI_COMPARTMENT_OCID"] = cfg["oci"]["accounts"][acct]["compartment_ocid"]
    subprocess.check_call(args)

# Sync whatever we built to R2
endpoint = os.environ["R2_ENDPOINT_URL"]
subprocess.check_call([
    "aws", "s3", "sync", outdir, "s3://cluster-tofu-state/production/inventory/",
    "--endpoint-url", endpoint, "--region", "us-east-1",
])
