# scripts/lib/test_talos_image_catalog.py
import hashlib
import tempfile
import unittest
from pathlib import Path

from talos_image_catalog import (
    catalog_readiness,
    evaluate_paths,
    schematic_id_for,
)


class TestTalosImageCatalog(unittest.TestCase):
    def test_schematic_id_for(self):
        with tempfile.TemporaryDirectory() as td:
            p = Path(td) / "cluster.yaml"
            p.write_bytes(b"hello\n")
            want = f"{hashlib.sha256(b'hello\n').hexdigest()}-v1.13.6"
            self.assertEqual(schematic_id_for(p, "v1.13.6"), want)

    def test_ready_when_catalog_complete(self):
        sid = "abc-v1"
        report = catalog_readiness(
            catalog={
                "schematic_id": sid,
                "formats": {
                    "contabo": {"url": "https://x/c.iso"},
                    "onprem": {"url": "https://x/o.iso"},
                    "oracle": {
                        "accounts": {
                            "bwire": {"ocid": "ocid1.image.oc1..x"},
                        }
                    },
                    "gcp": {
                        "accounts": {
                            "demo": {
                                "self_link": "projects/p/global/images/talos-x",
                            }
                        }
                    },
                },
            },
            accounts={
                "contabo": ["bwire"],
                "onprem": ["tindase"],
                "oracle": ["bwire"],
                "gcp": ["demo"],
            },
            expected_schematic_id=sid,
        )
        self.assertTrue(report["ready"])
        self.assertEqual(report["reasons"], [])
        self.assertEqual(report["missing_oracle"], [])
        self.assertEqual(report["missing_gcp"], [])

    def test_not_ready_missing_gcp_self_link(self):
        sid = "abc-v1"
        report = catalog_readiness(
            catalog={
                "schematic_id": sid,
                "formats": {
                    "contabo": {"url": "https://x/c.iso"},
                    "oracle": {"accounts": {}},
                    "gcp": {"accounts": {}},
                },
            },
            accounts={"contabo": ["bwire"], "oracle": [], "gcp": ["newproj"], "onprem": []},
            expected_schematic_id=sid,
        )
        self.assertFalse(report["ready"])
        self.assertEqual(report["missing_gcp"], ["newproj"])
        self.assertTrue(any("gcp accounts missing" in r for r in report["reasons"]))

    def test_not_ready_schematic_mismatch(self):
        report = catalog_readiness(
            catalog={"schematic_id": "old", "formats": {"contabo": {"url": "u"}}},
            accounts={"contabo": ["bwire"], "oracle": [], "gcp": [], "onprem": []},
            expected_schematic_id="new",
        )
        self.assertFalse(report["ready"])
        self.assertFalse(report["schematic_match"])

    def test_force_never_ready(self):
        report = catalog_readiness(
            catalog={
                "schematic_id": "s",
                "formats": {"contabo": {"url": "u"}},
            },
            accounts={"contabo": ["bwire"], "oracle": [], "gcp": [], "onprem": []},
            expected_schematic_id="s",
            force=True,
        )
        self.assertFalse(report["ready"])
        self.assertIn("force=true", report["reasons"])

    def test_empty_provider_lists_ok_without_formats(self):
        report = catalog_readiness(
            catalog={"schematic_id": "s", "formats": {}},
            accounts={"contabo": [], "oracle": [], "gcp": [], "onprem": []},
            expected_schematic_id="s",
        )
        self.assertTrue(report["ready"])

    def test_evaluate_paths_integration(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            schematic = root / "cluster.yaml"
            schematic.write_text("ext: []\n")
            accounts = root / "accounts.yaml"
            accounts.write_text("contabo: []\noracle: []\ngcp: []\nonprem: []\n")
            sid = schematic_id_for(schematic, "v1.0.0")
            catalog = root / "talos-images.yaml"
            catalog.write_text(f"schematic_id: {sid}\nformats: {{}}\n")
            report = evaluate_paths(
                accounts_yaml=accounts,
                catalog_yaml=catalog,
                schematic_path=schematic,
                talos_version="v1.0.0",
            )
            self.assertTrue(report["ready"])


if __name__ == "__main__":
    unittest.main()
