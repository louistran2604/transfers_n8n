from __future__ import annotations

import copy
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

from adapter import ADAPTER_SCHEMA, SchemaError, SofascoreAdapter
from models import validate_batch
from tests.fixture_transport import FixtureTransport


FIXTURES = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 7, 30, 5, 44, tzinfo=timezone.utc)


def mapped_item(
    player_id: str,
    team_id: str,
    tournament_id: str,
    season_id: str,
    name: str,
) -> dict:
    return {
        "item_key": f"provider:{player_id}",
        "reported_name": name,
        "known_provider_player_id": player_id,
        "aliases": [],
        "team_mapping": {
            "provider_team_id": team_id,
            "provider_unique_tournament_id": tournament_id,
        },
        "season_mapping": {
            "provider_season_id": season_id,
            "label": "25/26",
            "state": "latest_completed",
        },
    }


class AdapterNormalizationTests(unittest.TestCase):
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

    def test_rich_fixture_covers_normalized_contract_and_derivations(self):
        result = self.adapter.enrich(
            mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        )

        self.assertEqual("fresh", result["status"])
        self.assertEqual(
            {
                "provider",
                "provider_player_id",
                "stable_source_identifier",
                "score",
                "margin",
                "resolver_version",
            },
            set(result["identity"]),
        )
        self.assertEqual("sofascore:player:826643", result["identity"]["stable_source_identifier"])
        self.assertEqual(
            {
                "canonical_name",
                "current_club",
                "nationality",
                "age",
                "date_of_birth",
                "primary_position",
                "height_cm",
                "preferred_foot",
                "market_value",
                "market_value_currency",
                "retrieved_at",
            },
            set(result["profile"]),
        )
        self.assertEqual(27, result["profile"]["age"])
        self.assertEqual("1998-12-20", result["profile"]["date_of_birth"])
        self.assertEqual("Forward", result["profile"]["primary_position"])
        self.assertEqual(191_000_000, result["profile"]["market_value"])
        self.assertEqual("EUR", result["profile"]["market_value_currency"])
        self.assertEqual(
            {
                "competition",
                "provider_unique_tournament_id",
                "season",
                "provider_season_id",
                "season_state",
                "scope",
                "appearances",
                "starts",
                "minutes_played",
                "minutes_per_game",
                "goals",
                "expected_goals",
                "assists",
                "expected_assists",
                "average_rating",
                "clean_sheets",
                "saves",
                "retrieved_at",
            },
            set(result["statistics"]),
        )
        self.assertEqual(84.0, result["statistics"]["minutes_per_game"])
        self.assertEqual("selected_domestic_league_all_clubs", result["statistics"]["scope"])
        self.assertEqual(ADAPTER_SCHEMA, result["provenance"]["adapter_schema"])
        self.assertEqual({"profile", "statistics"}, set(result["provenance"]["raw_payloads"]))

    def test_sparse_fixture_keeps_missing_values_null_and_zero_values_numeric(self):
        result = self.adapter.enrich(
            mapped_item("845067", "193616", "626", "78589", "Nguyễn Quang Hải")
        )

        self.assertIsNone(result["statistics"]["expected_goals"])
        self.assertIsNone(result["statistics"]["expected_assists"])
        self.assertEqual(0, result["statistics"]["clean_sheets"])
        self.assertEqual(0, result["statistics"]["saves"])
        self.assertEqual("V-League 1", result["statistics"]["competition"])

    def test_goalkeeper_optional_fields_are_normalized(self):
        result = self.adapter.enrich(
            mapped_item("70988", "2829", "8", "77559", "Thibaut Courtois")
        )

        self.assertEqual("Goalkeeper", result["profile"]["primary_position"])
        self.assertEqual(13, result["statistics"]["clean_sheets"])
        self.assertEqual(70, result["statistics"]["saves"])
        self.assertEqual(0, result["statistics"]["goals"])

    def test_canonical_name_trims_collapses_whitespace_and_rejects_empty(self):
        endpoint = "player/826643"
        profile = copy.deepcopy(self.transport.responses[endpoint])
        profile["player"]["name"] = "  Kylian\t  Mbappé\n"
        self.transport.register(endpoint, profile)
        result = self.adapter.enrich(
            mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        )
        self.assertEqual("Kylian Mbappé", result["profile"]["canonical_name"])

        self.temporary.cleanup()
        self.temporary = tempfile.TemporaryDirectory()
        self.transport = FixtureTransport(FIXTURES)
        profile = copy.deepcopy(self.transport.responses[endpoint])
        profile["player"]["name"] = " \t\n "
        self.transport.register(endpoint, profile)
        self.adapter = SofascoreAdapter(
            self.transport,
            Path(self.temporary.name),
            min_interval_seconds=0,
            jitter_seconds=0,
            now=lambda: NOW,
        )
        result = self.adapter.enrich(
            mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        )
        self.assertIsNone(result["profile"]["canonical_name"])

    def test_nonfinite_decimal_statistics_fail_nullable(self):
        endpoint = "player/826643/unique-tournament/8/season/77559/statistics/overall"
        statistics = copy.deepcopy(self.transport.responses[endpoint])
        statistics["statistics"].update(
            {
                "expectedGoals": float("nan"),
                "expectedAssists": float("inf"),
                "rating": float("-inf"),
            }
        )
        self.transport.register(endpoint, statistics)

        result = self.adapter.enrich(
            mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        )

        self.assertIsNone(result["statistics"]["expected_goals"])
        self.assertIsNone(result["statistics"]["expected_assists"])
        self.assertIsNone(result["statistics"]["average_rating"])

    def test_profile_and_statistics_types_and_ranges_fail_nullable(self):
        profile_endpoint = "player/826643"
        profile = copy.deepcopy(self.transport.responses[profile_endpoint])
        profile["player"].update(
            {
                "name": 123,
                "dateOfBirthTimestamp": True,
                "height": 99,
                "preferredFoot": "both",
                "position": "unknown",
                "proposedMarketValueRaw": {"value": -1, "currency": "eur"},
            }
        )
        profile["player"]["country"] = {"name": []}
        self.transport.register(profile_endpoint, profile)
        statistics_endpoint = (
            "player/826643/unique-tournament/8/season/77559/statistics/overall"
        )
        statistics = copy.deepcopy(self.transport.responses[statistics_endpoint])
        statistics["statistics"].update(
            {
                "appearances": -1,
                "matchesStarted": 32,
                "minutesPlayed": -10,
                "goals": True,
                "expectedGoals": -0.1,
                "assists": "5",
                "expectedAssists": False,
                "rating": 10.1,
                "cleanSheet": -1,
                "saves": -1,
            }
        )
        self.transport.register(statistics_endpoint, statistics)

        result = self.adapter.enrich(
            mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        )

        self.assertEqual(
            {
                "canonical_name": None,
                "nationality": None,
                "age": None,
                "date_of_birth": None,
                "primary_position": None,
                "height_cm": None,
                "preferred_foot": None,
                "market_value": None,
                "market_value_currency": None,
            },
            {
                key: result["profile"][key]
                for key in (
                    "canonical_name",
                    "nationality",
                    "age",
                    "date_of_birth",
                    "primary_position",
                    "height_cm",
                    "preferred_foot",
                    "market_value",
                    "market_value_currency",
                )
            },
        )
        self.assertEqual(32, result["statistics"]["starts"])
        for field in (
            "appearances",
            "minutes_played",
            "minutes_per_game",
            "goals",
            "expected_goals",
            "assists",
            "expected_assists",
            "average_rating",
            "clean_sheets",
            "saves",
        ):
            self.assertIsNone(result["statistics"][field], field)

    def test_cold_unmapped_players_share_one_tournament_season_request(self):
        items = [
            {
                "item_key": "name:antoine-semenyo|club:manchester-city",
                "reported_name": "Antoine Semenyo",
                "aliases": [],
                "team_mapping": {
                    "provider_team_id": "17",
                    "provider_unique_tournament_id": "17",
                },
            },
            {
                "item_key": "name:florian-wirtz|club:liverpool",
                "reported_name": "Florian Wirtz",
                "aliases": [],
                "team_mapping": {
                    "provider_team_id": "44",
                    "provider_unique_tournament_id": "17",
                },
            },
        ]

        results = [self.adapter.enrich(item) for item in items]

        self.assertTrue(all(result["status"] == "fresh" for result in results))
        endpoints = [call["endpoint"] for call in self.transport.calls]
        self.assertEqual(8, len(endpoints))
        self.assertEqual(1, endpoints.count("unique-tournament/17/seasons"))
        self.assertEqual(1, endpoints.count("unique-tournament/17"))
        self.assertEqual(2, sum(endpoint.startswith("search/") for endpoint in endpoints))
        self.assertEqual(2, sum(endpoint.count("/") == 1 and endpoint.startswith("player/") for endpoint in endpoints))
        self.assertEqual(2, sum(endpoint.endswith("/statistics/overall") for endpoint in endpoints))

    def test_public_endpoint_paths_and_cache_ttls_are_exact(self):
        self.adapter.enrich(
            mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        )

        self.assertEqual(
            [
                "player/826643",
                "player/826643/unique-tournament/8/season/77559/statistics/overall",
            ],
            [call["endpoint"] for call in self.transport.calls],
        )
        self.assertEqual(
            [24 * 60 * 60, 12 * 60 * 60],
            [int(call["max_age"].total_seconds()) for call in self.transport.calls],
        )
        self.assertTrue(all(call["no_cache"] is False for call in self.transport.calls))

    def test_unmapped_player_uses_search_profile_metadata_seasons_and_statistics(self):
        result = self.adapter.enrich(
            {
                "item_key": "name:kylian-mbappe|club:real-madrid",
                "reported_name": "Kylian Mbappé",
                "aliases": [],
                "team_mapping": {
                    "provider_team_id": "2829",
                    "provider_unique_tournament_id": "8",
                },
                "season_mapping": {
                    "provider_season_id": "77559",
                    "label": "25/26",
                    "state": "latest_completed",
                },
            }
        )

        self.assertEqual("fresh", result["status"])
        self.assertEqual(
            [
                "search/all?q=Kylian%20Mbapp%C3%A9",
                "player/826643",
                "player/826643/unique-tournament/8/season/77559/statistics/overall",
            ],
            [call["endpoint"] for call in self.transport.calls],
        )
        self.assertEqual(3, result["provider_calls"])

    def test_mistyped_profile_and_statistics_envelopes_fail_closed(self):
        profile_endpoint = "player/826643"
        self.transport.register(profile_endpoint, {"player": []})
        with self.assertRaises(SchemaError):
            self.adapter.enrich(
                mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
            )

        self.transport.register(
            profile_endpoint,
            FixtureTransport(FIXTURES).responses[profile_endpoint],
        )
        statistics_endpoint = (
            "player/826643/unique-tournament/8/season/77559/statistics/overall"
        )
        self.transport.register(statistics_endpoint, {"statistics": []})
        with self.assertRaises(SchemaError):
            self.adapter.enrich(
                mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
            )

    def test_validator_deduplicates_identical_items_and_rejects_conflicts(self):
        item = mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        request_id, deadline_ms, players = validate_batch(
            {"request_id": "run:1", "players": [item, copy.deepcopy(item)]}
        )
        self.assertEqual("run:1", request_id)
        self.assertEqual(75_000, deadline_ms)
        self.assertEqual([item["item_key"]], [player["item_key"] for player in players])
        self.assertEqual([], players[0]["report_ids"])

        conflict = copy.deepcopy(item)
        conflict["reported_name"] = "Different"
        with self.assertRaisesRegex(ValueError, "duplicate item_key"):
            validate_batch({"request_id": "run:1", "players": [item, conflict]})


if __name__ == "__main__":
    unittest.main()
