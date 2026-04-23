#!/usr/bin/env python3
"""Build the JSON array consumed by configure-oci-wif.sh from R2 oracle auth.yaml files.

Usage: build-oci-auth-json.py <auth-dir>

<auth-dir> is a directory tree produced by:
    aws s3 sync s3://cluster-tofu-state/production/inventory/oracle/ <auth-dir>/
        --exclude "*" --include "*/auth.yaml"

Each subdirectory is an oracle account name; auth.yaml is plaintext YAML.
"""
import json, os, sys

try:
    import yaml
except ImportError:
    import subprocess
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "pyyaml"],
                          stdout=subprocess.DEVNULL)
    import yaml

base = sys.argv[1]
result = []
for entry in sorted(os.listdir(base)):
    auth_path = os.path.join(base, entry, "auth.yaml")
    if not os.path.exists(auth_path):
        continue
    data = yaml.safe_load(open(auth_path)) or {}
    auth = data.get("auth", data)
    oidc = auth.get("oidc_client_identifier")
    domain = auth.get("domain_base_url")
    tenancy = auth.get("tenancy_ocid")
    region = auth.get("region")
    if not all([oidc, domain, tenancy, region]):
        continue
    result.append({
        "profile": entry,
        "tenancy_ocid": tenancy,
        "region": region,
        "domain_base_url": domain,
        "oidc_client_identifier": oidc,
    })
print(json.dumps(result))
