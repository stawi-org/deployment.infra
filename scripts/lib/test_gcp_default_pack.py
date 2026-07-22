# scripts/lib/test_gcp_default_pack.py
import unittest

from gcp_default_pack import (
    DEFAULT_BOOT_DISK_GB,
    DEFAULT_MACHINE_TYPE,
    default_nodes,
    validate_nodes,
)


class TestGcpDefaultPack(unittest.TestCase):
    def test_default_nodes_count_and_names(self):
        nodes = default_nodes("stawi-prod", region="europe-west1")
        self.assertEqual(len(nodes), 2)
        self.assertIn("gcp-stawi-prod-node-1", nodes)
        self.assertIn("gcp-stawi-prod-node-2", nodes)

    def test_default_nodes_are_spot_workers(self):
        nodes = default_nodes("acme", region="us-central1")
        for name, n in nodes.items():
            self.assertEqual(n["role"], "worker")
            self.assertTrue(n["preemptible"])
            self.assertEqual(n["machine_type"], DEFAULT_MACHINE_TYPE)
            self.assertEqual(n["boot_disk_gb"], DEFAULT_BOOT_DISK_GB)
            self.assertEqual(n["zone"], "us-central1-b")

    def test_validate_rejects_controlplane(self):
        with self.assertRaises(ValueError):
            validate_nodes(
                {
                    "gcp-x-node-1": {
                        "role": "controlplane",
                        "machine_type": "e2-medium",
                        "zone": "europe-west1-b",
                        "boot_disk_gb": 50,
                        "preemptible": True,
                    }
                }
            )

    def test_validate_accepts_two_spot_workers(self):
        validate_nodes(default_nodes("x", region="europe-west1"))


if __name__ == "__main__":
    unittest.main()
