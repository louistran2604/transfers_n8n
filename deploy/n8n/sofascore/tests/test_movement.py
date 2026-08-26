from __future__ import annotations

import copy
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from adapter import SofascoreAdapter
from tests.fixture_transport import FixtureTransport


FIXTURES = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 7, 30, tzinfo=timezone.utc)


def item(player_id: str, team_id: str, name: str) -> dict:
    return {
        "item_key": f"provider:{player_id}",
        "reported_name": name,
        "known_provider_player_id": player_id,
        "aliases": [],
        "team_mapping": {
            "provider_team_id": team_id,
            "provider_unique_tournament_id": "17",
        },
        "season_mapping": {
            "provider_season_id": "76986",
            "label": "25/26",
            "state": "latest_completed",
        },
    }


class MovementTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.transport = FixtureTransport(FIXTURES)
        self.adapter = SofascoreAdapter(
            self.transport,
            Path(self.temporary.name),
            min_interval_seconds=0,
            jitter_seconds=0,
            now=lambda: NOW,
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_same_league_move_uses_combined_selected_league_total(self):
        result = self.adapter.enrich(item("934354", "17", "Antoine Semenyo"))
        self.assertEqual("Manchester City", result["profile"]["current_club"]["name"])
        self.assertEqual("Premier League", result["statistics"]["competition"])
        self.assertEqual(37, result["statistics"]["appearances"])
        self.assertEqual("selected_domestic_league_all_clubs", result["statistics"]["scope"])
        self.assertNotIn(
            "player/934354/transfer-history",
            [call["endpoint"] for call in self.transport.calls],
        )

    def test_cross_league_move_uses_current_club_league_only(self):
        result = self.adapter.enrich(item("1019322", "44", "Florian Wirtz"))
        self.assertEqual("Liverpool FC", result["profile"]["current_club"]["name"])
        self.assertEqual("Premier League", result["statistics"]["competition"])
        self.assertEqual(33, result["statistics"]["appearances"])
        self.assertNotIn("Bundesliga", str(result))

    def test_unattached_profile_makes_no_statistics_request(self):
        profile = copy.deepcopy(self.transport.responses["player/826643"])
        profile["player"]["team"] = None
        self.transport.register("player/826643", profile)
        result = self.adapter.enrich(
            {
                "item_key": "provider:826643",
                "reported_name": "Kylian Mbappé",
                "known_provider_player_id": "826643",
                "aliases": [],
            }
        )
        self.assertEqual("partial", result["status"])
        self.assertIsNone(result["statistics"])
        self.assertEqual("unattached", result["warnings"][0]["code"])
        self.assertEqual(["player/826643"], [call["endpoint"] for call in self.transport.calls])

    def test_lagging_profile_team_is_club_conflict_and_withholds_stats(self):
        conflicting = item("934354", "60", "Antoine Semenyo")
        result = self.adapter.enrich(conflicting)
        self.assertEqual("club_conflict", result["status"])
        self.assertIsNone(result["statistics"])
        self.assertEqual(["player/934354"], [call["endpoint"] for call in self.transport.calls])

    def test_completed_move_accepts_destination_profile_after_mapping_lags(self):
        moved = item("934354", "60", "Antoine Semenyo")
        moved.update({
            "classification": "official_confirmed",
            "move_type": "permanent",
            "destination_club_name": "Manchester City",
        })
        result = self.adapter.enrich(moved)
        self.assertEqual("fresh", result["status"])
        self.assertEqual("Manchester City", result["profile"]["current_club"]["name"])
        self.assertEqual("Premier League", result["statistics"]["competition"])
        self.assertEqual(
            [
                "player/934354",
                "unique-tournament/17",
                "player/934354/unique-tournament/17/season/76986/statistics/overall",
            ],
            [call["endpoint"] for call in self.transport.calls],
        )


if __name__ == "__main__":
    unittest.main()
