"""Unit tests for oci_free_tier helpers. Run: python3 -m pytest scripts/lib/test_oci_free_tier.py -q"""

from __future__ import annotations

import unittest

from oci_free_tier import (
    free_tier_pack,
    reconcile_nodes,
    validate_account,
    validate_inventory_tree,
)


class TestValidateAccount(unittest.TestCase):
    def test_single_full_node_ok(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 2,
                    "memory_gb": 12,
                    "boot_volume_size_gb": 100,
                }
            },
        )
        self.assertTrue(r.ok, r.violations)
        self.assertEqual(r.ocpus, 2)
        self.assertEqual(r.memory_gb, 12)
        self.assertEqual(r.boot_gb, 100)

    def test_legacy_4_24_over(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 4,
                    "memory_gb": 24,
                    "boot_volume_size_gb": 180,
                }
            },
        )
        self.assertFalse(r.ok)
        codes = {v.code for v in r.violations}
        self.assertIn("ocpu_total", codes)
        self.assertIn("memory_total", codes)

    def test_two_nodes_default_boot_over_block(self):
        # missing boot → 100 default each = 200 OK
        r = validate_account(
            "a",
            {
                "n1": {"shape": "VM.Standard.A1.Flex", "ocpus": 1, "memory_gb": 6},
                "n2": {"shape": "VM.Standard.A1.Flex", "ocpus": 1, "memory_gb": 6},
            },
        )
        self.assertTrue(r.ok, r.violations)
        self.assertEqual(r.boot_gb, 200)

    def test_two_nodes_180_boot_over(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": 180,
                },
                "n2": {
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": 180,
                },
            },
        )
        self.assertFalse(r.ok)
        self.assertTrue(any(v.code == "boot_total" for v in r.violations))

    def test_three_nodes_rejected(self):
        nodes = {
            f"n{i}": {
                "shape": "VM.Standard.A1.Flex",
                "ocpus": 1,
                "memory_gb": 6,
                "boot_volume_size_gb": 50,
            }
            for i in range(3)
        }
        r = validate_account("a", nodes)
        self.assertFalse(r.ok)
        self.assertTrue(any(v.code == "node_count" for v in r.violations))

    def test_non_a1_shape(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "shape": "VM.Standard.E4.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": 50,
                }
            },
        )
        self.assertFalse(r.ok)
        self.assertTrue(any(v.code == "shape" for v in r.violations))

    def test_empty_ok(self):
        r = validate_account("empty", {})
        self.assertTrue(r.ok)


class TestReconcile(unittest.TestCase):
    def test_pack_one(self):
        self.assertEqual(
            free_tier_pack(1),
            [{"ocpus": 2, "memory_gb": 12, "boot_volume_size_gb": 100}],
        )

    def test_pack_two(self):
        packs = free_tier_pack(2)
        self.assertEqual(sum(p["ocpus"] for p in packs), 2)
        self.assertEqual(sum(p["memory_gb"] for p in packs), 12)

    def test_reconcile_preserves_labels(self):
        nodes = {
            "oci-x-node-1": {
                "role": "worker",
                "ocpus": 4,
                "memory_gb": 24,
                "labels": {"node.stawi.org/external-load-balancer": "true"},
                "provider_data": {"status": "running"},
            }
        }
        out = reconcile_nodes(nodes)
        self.assertEqual(out["oci-x-node-1"]["ocpus"], 2)
        self.assertEqual(out["oci-x-node-1"]["memory_gb"], 12)
        self.assertEqual(out["oci-x-node-1"]["boot_volume_size_gb"], 100)
        self.assertEqual(
            out["oci-x-node-1"]["labels"]["node.stawi.org/external-load-balancer"],
            "true",
        )
        self.assertEqual(out["oci-x-node-1"]["provider_data"]["status"], "running")
        r = validate_account("x", out)
        self.assertTrue(r.ok, r.violations)

    def test_reconcile_two_nodes(self):
        nodes = {
            "a": {"role": "controlplane", "ocpus": 2, "memory_gb": 12},
            "b": {"role": "worker", "ocpus": 2, "memory_gb": 12},
        }
        out = reconcile_nodes(nodes)
        r = validate_account("x", out)
        self.assertTrue(r.ok, r.violations)

    def test_tree(self):
        reports = validate_inventory_tree(
            {
                "good": {
                    "nodes": {
                        "n1": {
                            "shape": "VM.Standard.A1.Flex",
                            "ocpus": 2,
                            "memory_gb": 12,
                            "boot_volume_size_gb": 100,
                        }
                    }
                },
                "bad": {
                    "nodes": {
                        "n1": {
                            "shape": "VM.Standard.A1.Flex",
                            "ocpus": 4,
                            "memory_gb": 24,
                        }
                    }
                },
            }
        )
        by = {r.account: r for r in reports}
        self.assertTrue(by["good"].ok)
        self.assertFalse(by["bad"].ok)


if __name__ == "__main__":
    unittest.main()
