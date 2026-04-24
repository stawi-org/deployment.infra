#!/usr/bin/env python3
"""Translate one production/config/<provider>/<account>.yaml document into
inventory shape and write {auth.yaml, nodes.yaml} into <out_dir>.

Used by .github/workflows/migrate-config-to-inventory.yml. Pure transform
— no I/O outside the two file writes; no encryption (the workflow handles
contabo auth encryption after this script returns).

Usage:
    migrate_config_doc.py <src_yaml> <out_dir> <inv_provider> <account>
        inv_provider ∈ {contabo, oracle, onprem}
"""

from __future__ import annotations

import os
import sys

import yaml


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    src, out, provider, account = sys.argv[1:]

    doc = yaml.safe_load(open(src))
    container_key = {"contabo": "contabo", "oracle": "oci", "onprem": "onprem"}[provider]
    acct = doc[container_key]["accounts"][account]

    auth_doc = {"provider": provider, "account": account, "auth": dict(acct.get("auth", {}))}
    if provider == "oracle":
        for k in ("tenancy_ocid", "compartment_ocid", "region"):
            if k in acct:
                auth_doc["auth"][k] = acct[k]
        auth_doc["auth"].setdefault("config_file_profile", account)
        auth_doc["auth"].setdefault("auth_method", "SecurityToken")
    with open(os.path.join(out, "auth.yaml"), "w") as fh:
        yaml.safe_dump(auth_doc, fh, sort_keys=True, default_flow_style=False)

    nodes_doc = {
        "provider": provider,
        "account": account,
        "labels": acct.get("labels", {}),
        "annotations": acct.get("annotations", {}),
        "nodes": acct.get("nodes", {}),
    }
    if provider == "oracle":
        for k in ("vcn_cidr", "enable_ipv6", "bastion_client_cidr_block_allow_list"):
            if k in acct:
                nodes_doc[k] = acct[k]
    with open(os.path.join(out, "nodes.yaml"), "w") as fh:
        yaml.safe_dump(nodes_doc, fh, sort_keys=True, default_flow_style=False)


if __name__ == "__main__":
    main()
