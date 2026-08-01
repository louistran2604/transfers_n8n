from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from adapter import SchemaError, SofascoreAdapter
from tests.fixture_transport import FixtureTransport


FIXTURES = Path(__file__).parent / "fixtures"


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.cache_dir = Path(self.temporary.name)
        self.transport = FixtureTransport(FIXTURES)
        self.adapter = SofascoreAdapter(
            self.transport,
            self.cache_dir,
            min_interval_seconds=0,
            jitter_seconds=0,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_raw_miss_write_then_hit_uses_public_get_cache_contract(self):
        first, first_status = self.adapter.fetch_json("player/826643", "profile", 24)
        second, second_status = self.adapter.fetch_json("player/826643", "profile", 24)
        self.assertEqual(first, second)
        self.assertEqual("miss", first_status)
        self.assertEqual("hit", second_status)
        self.assertTrue((self.cache_dir / "profile.json").is_file())
        self.assertEqual([False, False], [call["no_cache"] for call in self.transport.calls])
        self.assertEqual(
            [24 * 60 * 60, 24 * 60 * 60],
            [int(call["max_age"].total_seconds()) for call in self.transport.calls],
        )

    def test_corrupt_cache_quarantines_and_performs_exactly_one_bypass(self):
        (self.cache_dir / "profile.json").write_text("{broken")
        self.transport.register("player/826643", b"{still-broken")
        with self.assertRaises(SchemaError):
            self.adapter.fetch_json("player/826643", "profile", 24)
        self.assertEqual([False, True], [call["no_cache"] for call in self.transport.calls[-2:]])
        self.assertEqual(2, len(list(self.cache_dir.glob("profile.json.corrupt-*"))))

    def test_normalized_last_good_survives_failed_bypass(self):
        expected, _ = self.adapter.fetch_json("player/826643", "profile", 24)
        (self.cache_dir / "profile.json").write_text("{broken")
        self.transport.register("player/826643", b"{still-broken")
        actual, status = self.adapter.fetch_json("player/826643", "profile", 24)
        self.assertEqual(expected, actual)
        self.assertEqual("stale", status)

    def test_cache_file_persists_across_adapter_restart(self):
        expected, _ = self.adapter.fetch_json("player/826643", "profile", 24)
        restarted_transport = FixtureTransport(FIXTURES)
        restarted_transport.register("player/826643", AssertionError("network forbidden"))
        restarted = SofascoreAdapter(
            restarted_transport,
            self.cache_dir,
            min_interval_seconds=0,
            jitter_seconds=0,
        )
        actual, status = restarted.fetch_json("player/826643", "profile", 24)
        self.assertEqual(expected, actual)
        self.assertEqual("hit", status)

    def test_profile_stats_and_mapping_ttls_are_distinct(self):
        self.adapter.enrich(
            {
                "item_key": "provider:826643",
                "reported_name": "Kylian Mbappé",
                "known_provider_player_id": "826643",
                "aliases": [],
            }
        )
        ttl_by_endpoint = {
            call["endpoint"]: int(call["max_age"].total_seconds() / 3600)
            for call in self.transport.calls
        }
        self.assertEqual(24, ttl_by_endpoint["player/826643"])
        self.assertEqual(24, ttl_by_endpoint["unique-tournament/8"])
        self.assertEqual(24, ttl_by_endpoint["unique-tournament/8/seasons"])
        self.assertEqual(
            12,
            ttl_by_endpoint[
                "player/826643/unique-tournament/8/season/77559/statistics/overall"
            ],
        )


if __name__ == "__main__":
    unittest.main()
