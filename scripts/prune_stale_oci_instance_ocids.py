#!/usr/bin/env python3
"""Remove nodes[*].provider_data.oci_instance_ocid from a state.yaml.

Rewrites in place. Leaves every other field intact. Empty provider_data
dicts are removed too so the file stays tidy.

Used by scripts/prune-stale-oci-instance-ocids.sh — see there for the
workflow context.
"""

from __future__ import annotations

import sys

import yaml


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    path = sys.argv[1]
    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}

    nodes = doc.get("nodes", {}) or {}
    for key, node in list(nodes.items()):
        pd = (node or {}).get("provider_data", {}) or {}
        if "oci_instance_ocid" in pd:
            del pd["oci_instance_ocid"]
        if pd:
            nodes[key]["provider_data"] = pd
        elif node is not None:
            nodes[key].pop("provider_data", None)

    doc["nodes"] = nodes
    with open(path, "w") as fh:
        yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=True)


if __name__ == "__main__":
    main()
