"""Deterministic YAML rendering for the R2 inventory tree."""
from __future__ import annotations

from copy import deepcopy
from typing import Any, Mapping

import yaml


class _SortedDumper(yaml.SafeDumper):
    """Dumps mappings with sorted keys and wide column width for readability."""


def _represent_dict(dumper: yaml.SafeDumper, data: Mapping[str, Any]):
    return dumper.represent_mapping(
        "tag:yaml.org,2002:map", sorted(data.items(), key=lambda kv: kv[0])
    )


_SortedDumper.add_representer(dict, _represent_dict)


def _dump(obj: Any) -> str:
    return yaml.dump(obj, Dumper=_SortedDumper, default_flow_style=False, sort_keys=False, width=100)


def render_nodes_yaml(provider: str, account: str, account_meta: Mapping, nodes: Mapping) -> str:
    payload = {
        "provider": provider,
        "account": account,
        "labels": dict(account_meta.get("labels", {})),
        "annotations": dict(account_meta.get("annotations", {})),
        "nodes": {k: dict(v) for k, v in nodes.items()},
    }
    return _dump(payload)


def render_state_yaml(provider: str, account: str, node_provider_data: Mapping[str, Mapping]) -> str:
    payload = {
        "provider": provider,
        "account": account,
        "nodes": {k: {"provider_data": dict(v)} for k, v in node_provider_data.items()},
    }
    return _dump(payload)


def merge_state(existing: Mapping, incoming: Mapping) -> dict:
    """Deep-merge inventory YAMLs without losing sibling subtrees."""
    merged = deepcopy(dict(existing)) if existing else {}
    if "nodes" not in merged:
        merged["nodes"] = {}
    for k, v in (incoming.get("nodes") or {}).items():
        merged["nodes"].setdefault(k, {})
        for sub_k, sub_v in v.items():
            merged["nodes"][k][sub_k] = deepcopy(sub_v)
    for top_k, top_v in incoming.items():
        if top_k != "nodes":
            merged[top_k] = deepcopy(top_v)
    return merged
