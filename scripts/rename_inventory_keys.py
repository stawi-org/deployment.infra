#!/usr/bin/env python3
"""Apply a key-rename map to a nodes.yaml file in place.

Usage: rename_inventory_keys.py <path> <mapping_json>

Rewrites .nodes[<old>] → .nodes[<new>] for every (old, new) in
mapping_json that matches a key in the current file. Writes "changed"
to stdout if the file was modified, "unchanged" otherwise.

Idempotent: a second run where old keys are already absent is a no-op.
"""

from __future__ import annotations

import json
import sys

import yaml


def main() -> None:
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, mapping_json = sys.argv[1], sys.argv[2]
    mapping = json.loads(mapping_json)

    with open(path) as fh:
        doc = yaml.safe_load(fh) or {}

    nodes = doc.get("nodes", {}) or {}
    changed = False
    for old_key, new_key in mapping.items():
        if old_key in nodes and old_key != new_key:
            nodes[new_key] = nodes.pop(old_key)
            changed = True
    if changed:
        doc["nodes"] = nodes
        with open(path, "w") as fh:
            yaml.safe_dump(doc, fh, default_flow_style=False, sort_keys=True)
        print("changed")
    else:
        print("unchanged")


if __name__ == "__main__":
    main()
