"""Unit tests for omni_machine_match."""

from __future__ import annotations

import unittest

from omni_machine_match import match_machine


def _ms(mid: str, host: str, *, connected: bool, addrs: list[str] | None = None):
    return {
        "metadata": {"id": mid},
        "spec": {
            "connected": connected,
            "network": {
                "hostname": host,
                "addresses": addrs or [],
            },
        },
    }


class TestMatchMachine(unittest.TestCase):
    def test_preferred_connected(self):
        machines = [
            _ms("old", "node-a", connected=False),
            _ms("new", "node-a", connected=True),
        ]
        r = match_machine(machines, preferred_id="new", hostname="node-a")
        self.assertEqual(r.machine_id, "new")
        self.assertEqual(r.reason, "preferred")

    def test_preferred_stale_uses_connected_twin(self):
        machines = [
            _ms("old", "node-a", connected=False),
            _ms("new", "node-a", connected=True),
        ]
        r = match_machine(machines, preferred_id="old", hostname="node-a")
        self.assertEqual(r.machine_id, "new")
        self.assertEqual(r.reason, "preferred_stale_twin")

    def test_preferred_offline_no_twin_keeps_pin(self):
        machines = [_ms("old", "node-a", connected=False)]
        r = match_machine(machines, preferred_id="old", hostname="node-a")
        self.assertEqual(r.machine_id, "old")
        self.assertEqual(r.reason, "preferred")

    def test_hostname_prefers_connected(self):
        machines = [
            _ms("a", "node-a", connected=False),
            _ms("b", "node-a", connected=True),
        ]
        r = match_machine(machines, hostname="node-a")
        self.assertEqual(r.machine_id, "b")
        self.assertEqual(r.reason, "hostname")

    def test_ipv4_fallback(self):
        machines = [
            _ms("x", "other", connected=True, addrs=["10.0.0.5/32"]),
            _ms("y", "other2", connected=True, addrs=["10.0.0.9/24"]),
        ]
        r = match_machine(machines, hostname="missing", ipv4="10.0.0.9")
        self.assertEqual(r.machine_id, "y")
        self.assertEqual(r.reason, "ipv4")

    def test_none(self):
        r = match_machine([], hostname="nope")
        self.assertEqual(r.machine_id, "")
        self.assertEqual(r.reason, "none")


if __name__ == "__main__":
    unittest.main()
