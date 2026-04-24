"""Tests for scripts/lib/inventory_yaml.py — deterministic YAML rendering."""
import pytest
from inventory_yaml import render_nodes_yaml, render_state_yaml, merge_state


def test_render_nodes_yaml_sorted_keys():
    out = render_nodes_yaml(
        provider="contabo",
        account="stawi-contabo",
        account_meta={"labels": {"x": "1"}, "annotations": {}},
        nodes={"b-node": {"role": "worker"}, "a-node": {"role": "controlplane"}},
    )
    assert out.index("a-node") < out.index("b-node")
    assert "account: stawi-contabo" in out


def test_render_state_yaml_with_provider_data():
    out = render_state_yaml(
        provider="contabo",
        account="stawi-contabo",
        node_provider_data={
            "api-1": {"contabo_instance_id": "202727783", "ipv4": "1.2.3.4"},
        },
    )
    assert "contabo_instance_id: '202727783'" in out or 'contabo_instance_id: "202727783"' in out


def test_merge_state_preserves_existing_subtree():
    existing = {"nodes": {"api-1": {"talos_state": {"last_applied_version": "v1.12.5"}}}}
    incoming = {"nodes": {"api-1": {"provider_data": {"ipv4": "1.2.3.4"}}}}
    merged = merge_state(existing, incoming)
    assert merged["nodes"]["api-1"]["talos_state"]["last_applied_version"] == "v1.12.5"
    assert merged["nodes"]["api-1"]["provider_data"]["ipv4"] == "1.2.3.4"
