from __future__ import annotations

import os
import tempfile
import unittest
from pathlib import Path

from adapter import SofascoreAdapter, create_reader


LIVE_APPROVED = (
    os.environ.get("SOFASCORE_LIVE_ACCEPTANCE") == "1"
    and os.environ.get("SOFASCORE_PROVIDER_POLICY_APPROVED") == "1"
)


@unittest.skipUnless(
    LIVE_APPROVED,
    "requires recorded provider-policy approval plus both explicit live flags",
)
class LiveAcceptanceTests(unittest.TestCase):
    def test_six_subject_serial_read_only_acceptance(self):
        subjects = [
            ("826643", "Kylian Mbappé"),
            (None, "John Smith"),
            ("845067", "Nguyễn Quang Hải"),
            ("70988", "Thibaut Courtois"),
            ("934354", "Antoine Semenyo"),
            ("1019322", "Florian Wirtz"),
        ]
        with tempfile.TemporaryDirectory(prefix="sofascore-live-") as temporary:
            cache_dir = Path(temporary)
            adapter = SofascoreAdapter(
                create_reader(cache_dir),
                cache_dir,
                min_interval_seconds=1,
                jitter_seconds=0.25,
            )
            summaries = []
            for provider_player_id, name in subjects:
                item = {
                    "item_key": f"live:{name}",
                    "reported_name": name,
                    "known_provider_player_id": provider_player_id,
                    "aliases": [],
                }
                result = adapter.enrich(item)
                summaries.append(
                    {
                        "name": name,
                        "status": result["status"],
                        "provider_player_id": (
                            result.get("identity") or {}
                        ).get("provider_player_id"),
                        "has_profile": result.get("profile") is not None,
                        "has_statistics": result.get("statistics") is not None,
                        "competition": (result.get("statistics") or {}).get("competition"),
                        "season_state": (result.get("statistics") or {}).get("season_state"),
                        "expected_goals": (result.get("statistics") or {}).get("expected_goals"),
                        "saves": (result.get("statistics") or {}).get("saves"),
                    }
                )

            self.assertEqual(6, len(summaries))
            john = next(row for row in summaries if row["name"] == "John Smith")
            self.assertEqual("ambiguous", john["status"])
            self.assertIsNone(john["provider_player_id"])
            courtois = next(row for row in summaries if row["name"] == "Thibaut Courtois")
            self.assertTrue(courtois["has_profile"])
            self.assertIsInstance(courtois["saves"], int)
            quang_hai = next(row for row in summaries if row["name"] == "Nguyễn Quang Hải")
            self.assertTrue(quang_hai["has_profile"])
            self.assertEqual("V-League 1", quang_hai["competition"])
            self.assertIsNone(quang_hai["expected_goals"])
            for name in ("Antoine Semenyo", "Florian Wirtz"):
                moved = next(row for row in summaries if row["name"] == name)
                self.assertEqual("Premier League", moved["competition"])
            self.assertTrue(all(
                row["season_state"] in {None, "active", "latest_completed"}
                for row in summaries
            ))
            self.assertTrue(all(set(row) == {
                "name",
                "status",
                "provider_player_id",
                "has_profile",
                "has_statistics",
                "competition",
                "season_state",
                "expected_goals",
                "saves",
            } for row in summaries))


if __name__ == "__main__":
    unittest.main()
