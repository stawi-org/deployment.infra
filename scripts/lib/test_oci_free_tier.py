"""Unit tests for oci_free_tier helpers. Run: python3 -m unittest test_oci_free_tier.py -q"""

from __future__ import annotations

import unittest

from oci_free_tier import (
    BOOT_BUFFER_GB,
    MAX_BOOT_USABLE_GB,
    free_tier_pack,
    reconcile_nodes,
    validate_account,
    validate_inventory_tree,
)


class TestValidateAccount(unittest.TestCase):
    def test_single_worker_free_ok(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "role": "worker",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 2,
                    "memory_gb": 12,
                    "boot_volume_size_gb": MAX_BOOT_USABLE_GB,
                }
            },
        )
        self.assertTrue(r.ok, r.violations)
        self.assertEqual(r.ocpus, 2)
        self.assertEqual(r.memory_gb, 12)
        self.assertEqual(r.boot_gb, MAX_BOOT_USABLE_GB)

    def test_legacy_4_24_over(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "role": "worker",
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

    def test_two_nodes_free_split_ok(self):
        half = MAX_BOOT_USABLE_GB // 2
        r = validate_account(
            "a",
            {
                "n1": {
                    "role": "controlplane",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": half,
                },
                "n2": {
                    "role": "worker",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": half,
                },
            },
        )
        self.assertTrue(r.ok, r.violations)
        self.assertEqual(r.ocpus, 2)
        self.assertEqual(r.memory_gb, 12)
        self.assertEqual(r.boot_gb, half * 2)

    def test_two_nodes_2_12_each_over_compute(self):
        half = MAX_BOOT_USABLE_GB // 2
        r = validate_account(
            "a",
            {
                "n1": {
                    "role": "controlplane",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 2,
                    "memory_gb": 12,
                    "boot_volume_size_gb": half,
                },
                "n2": {
                    "role": "worker",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 2,
                    "memory_gb": 12,
                    "boot_volume_size_gb": half,
                },
            },
        )
        self.assertFalse(r.ok)
        codes = {v.code for v in r.violations}
        self.assertIn("ocpu_total", codes)
        self.assertIn("memory_total", codes)

    def test_boot_hits_hard_cap_without_buffer_fails(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "role": "controlplane",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": 100,
                },
                "n2": {
                    "role": "worker",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": 100,
                },
            },
        )
        self.assertFalse(r.ok)
        self.assertTrue(any(v.code == "boot_total" for v in r.violations))

    def test_two_nodes_180_boot_over(self):
        r = validate_account(
            "a",
            {
                "n1": {
                    "role": "worker",
                    "shape": "VM.Standard.A1.Flex",
                    "ocpus": 1,
                    "memory_gb": 6,
                    "boot_volume_size_gb": 180,
                },
                "n2": {
                    "role": "worker",
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
                "role": "worker",
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
                    "role": "worker",
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

    def test_buffer_constant(self):
        self.assertEqual(BOOT_BUFFER_GB, 4)
        self.assertEqual(MAX_BOOT_USABLE_GB, 196)


class TestReconcile(unittest.TestCase):
    def test_pack_one_worker(self):
        self.assertEqual(
            free_tier_pack(1),
            [{"ocpus": 2, "memory_gb": 12, "boot_volume_size_gb": MAX_BOOT_USABLE_GB}],
        )

    def test_pack_two_roles_free_split(self):
        packs = free_tier_pack(2, roles=["controlplane", "worker"])
        self.assertEqual(sum(p["ocpus"] for p in packs), 2)
        self.assertEqual(sum(p["memory_gb"] for p in packs), 12)
        self.assertEqual(packs[0]["ocpus"], 1)
        self.assertEqual(packs[1]["ocpus"], 1)
        self.assertEqual(sum(p["boot_volume_size_gb"] for p in packs), MAX_BOOT_USABLE_GB)

    def test_reconcile_worker_to_2_12(self):
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
        self.assertEqual(out["oci-x-node-1"]["boot_volume_size_gb"], MAX_BOOT_USABLE_GB)
        self.assertEqual(
            out["oci-x-node-1"]["labels"]["node.stawi.org/external-load-balancer"],
            "true",
        )
        self.assertEqual(out["oci-x-node-1"]["provider_data"]["status"], "running")
        r = validate_account("x", out)
        self.assertTrue(r.ok, r.violations)

    def test_reconcile_two_nodes_free_split(self):
        nodes = {
            "a": {"role": "controlplane", "ocpus": 2, "memory_gb": 12},
            "b": {"role": "worker", "ocpus": 2, "memory_gb": 12},
        }
        out = reconcile_nodes(nodes)
        self.assertEqual(out["a"]["ocpus"], 1)
        self.assertEqual(out["a"]["memory_gb"], 6)
        self.assertEqual(out["b"]["ocpus"], 1)
        self.assertEqual(out["b"]["memory_gb"], 6)
        self.assertEqual(
            out["a"]["boot_volume_size_gb"] + out["b"]["boot_volume_size_gb"],
            MAX_BOOT_USABLE_GB,
        )
        r = validate_account("x", out)
        self.assertTrue(r.ok, r.violations)

    def test_reconcile_two_controlplanes(self):
        nodes = {
            "a": {"role": "controlplane", "ocpus": 2, "memory_gb": 12},
            "b": {"role": "controlplane", "ocpus": 2, "memory_gb": 12},
        }
        out = reconcile_nodes(nodes)
        self.assertEqual(out["a"]["ocpus"], 1)
        self.assertEqual(out["b"]["ocpus"], 1)
        self.assertEqual(out["a"]["memory_gb"], 6)
        self.assertEqual(out["b"]["memory_gb"], 6)
        r = validate_account("x", out)
        self.assertTrue(r.ok, r.violations)

    def test_tree(self):
        reports = validate_inventory_tree(
            {
                "good": {
                    "nodes": {
                        "n1": {
                            "role": "worker",
                            "shape": "VM.Standard.A1.Flex",
                            "ocpus": 2,
                            "memory_gb": 12,
                            "boot_volume_size_gb": MAX_BOOT_USABLE_GB,
                        }
                    }
                },
                "bad": {
                    "nodes": {
                        "n1": {
                            "role": "worker",
                            "shape": "VM.Standard.A1.Flex",
                            "ocpus": 4,
                            "memory_gb": 24,
                            "boot_volume_size_gb": 100,
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
