from __future__ import annotations

import copy
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest.mock import patch

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
        self.assertEqual("identity-v8", result["resolver_version"])
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

    def test_identity_resolution_receives_curated_player_and_club_aliases(self):
        self.transport.register("search/all?q=Destiny%20Udogie", {"results": []})
        self.transport.register("search/all?q=Udogie", {"results": []})
        item = {
            "item_key": "name:destiny-udogie|club:union-saint-gilloise",
            "reported_name": "Destiny Udogie",
            "aliases": ["Udogie"],
            "current_club_name": "Union Saint-Gilloise",
            "current_club_aliases": [
                "Union Saint-Gilloise",
                "Royale Union Saint-Gilloise",
            ],
        }

        with patch(
            "adapter.resolve_search",
            return_value={"status": "unresolved", "candidates": []},
        ) as resolver:
            result = self.adapter.enrich(item)

        self.assertEqual("unresolved", result["status"])
        self.assertEqual(2, resolver.call_count)
        for call in resolver.call_args_list:
            self.assertEqual(["Udogie"], call.kwargs["aliases"])
            self.assertEqual(
                [
                    "Union Saint-Gilloise",
                    "Union Saint-Gilloise",
                    "Royale Union Saint-Gilloise",
                ],
                call.kwargs["reported_club_names"],
            )

    def test_curated_porto_request_resolves_rodrigo_mora_and_continues_to_profile(self):
        self.transport.register("search/all?q=Rodrigo%20Mora", {
            "results": [
                {
                    "type": "player",
                    "entity": {
                        "id": 1410240,
                        "name": "Rodrigo Mora",
                        "team": {"id": 3000, "name": "FC Porto", "sport": {"slug": "football"}, "gender": "M"},
                    },
                },
                {
                    "type": "player",
                    "entity": {
                        "id": 40772,
                        "name": "Rodrigo Mora",
                        "team": {"id": 4000, "name": "Alas Argentinas", "sport": {"slug": "football"}, "gender": "M"},
                    },
                },
            ]
        })
        self.transport.register("player/1410240", {
            "player": {
                "id": 1410240,
                "name": "Rodrigo Mora",
                "team": {
                    "id": 3000,
                    "name": "FC Porto",
                    "primaryUniqueTournament": {"id": 17, "name": "Primeira Liga"},
                },
                "country": {"name": "Portugal"},
            }
        })
        self.transport.register("player/1410240/unique-tournament/17/season/76986/statistics/overall", {
            "statistics": {
                "appearances": 1,
                "matchesStarted": 1,
                "minutesPlayed": 90,
                "goals": 1,
                "expectedGoals": 0.5,
                "assists": 0,
                "expectedAssists": 0.1,
                "rating": 7.5,
                "cleanSheet": 0,
                "saves": 0,
            }
        })

        result = self.adapter.enrich({
            "item_key": "name:rodrigo-mora|club:porto",
            "reported_name": "Rodrigo Mora",
            "current_club_name": "Porto",
            "current_club_aliases": ["Porto", "FC Porto"],
            "aliases": [],
            "team_mapping": {"provider_team_id": "3000", "provider_unique_tournament_id": "17"},
            "season_mapping": {"provider_season_id": "76986", "label": "2025/26", "state": "latest_completed"},
        })

        self.assertEqual("fresh", result["status"])
        self.assertEqual("1410240", result["identity"]["provider_player_id"])
        self.assertEqual(80, result["identity"]["score"])
        self.assertEqual(30, result["identity"]["margin"])
        self.assertEqual("FC Porto", result["profile"]["current_club"]["name"])
        self.assertEqual(
            [
                "search/all?q=Rodrigo%20Mora",
                "player/1410240",
                "player/1410240/unique-tournament/17/season/76986/statistics/overall",
            ],
            [call["endpoint"] for call in self.transport.calls],
        )

    def test_active_season_mapping_refreshes_to_latest_completed(self):
        result = self.adapter.enrich({
            "item_key": "provider:826643",
            "reported_name": "Kylian Mbappé",
            "known_provider_player_id": "826643",
            "team_mapping": {"provider_team_id": "2829", "provider_unique_tournament_id": "8"},
            "season_mapping": {"provider_season_id": "97268", "label": "26/27", "state": "active"},
            "aliases": [],
        })

        self.assertEqual("fresh", result["status"])
        self.assertEqual("77559", result["statistics"]["provider_season_id"])
        self.assertEqual("latest_completed", result["statistics"]["season_state"])
        self.assertEqual(
            [
                "player/826643",
                "unique-tournament/8/seasons",
                "unique-tournament/8",
                "player/826643/unique-tournament/8/season/77559/statistics/overall",
            ],
            [call["endpoint"] for call in self.transport.calls],
        )

    def test_empty_identity_map_bootstraps_profile_statistics_with_bounded_cache_calls(self):
        item = {
            "item_key": "name:kylian-mbappe|club:real-madrid",
            "reported_name": "Kylian Mbappé",
            "current_club_name": "Real Madrid",
            "aliases": [],
        }
        result = self.adapter.enrich(item)

        self.assertEqual("fresh", result["status"])
        self.assertEqual("826643", result["identity"]["provider_player_id"])
        self.assertEqual(80, result["identity"]["score"])
        self.assertEqual("Real Madrid", result["profile"]["current_club"]["name"])
        self.assertEqual(25, result["statistics"]["goals"])
        self.assertEqual(5, result["provider_calls"])
        self.assertEqual(
            [
                "search/all?q=Kylian%20Mbapp%C3%A9",
                "player/826643",
                "unique-tournament/8",
                "unique-tournament/8/seasons",
                "player/826643/unique-tournament/8/season/77559/statistics/overall",
            ],
            [call["endpoint"] for call in self.transport.calls],
        )

        cached = self.adapter.enrich(item)
        self.assertEqual("fresh", cached["status"])
        self.assertEqual(3, cached["provider_calls"])
        self.assertEqual("hit", cached["provenance"]["profile_cache"])
        self.assertEqual("hit", cached["provenance"]["statistics_cache"])

    def test_empty_identity_map_accepts_the_reported_destination_club(self):
        self.transport.register("player/826643/transfer-history", {"transferHistory": [{
            "transferFrom": {"id": 1, "name": "Former Club"},
            "transferTo": {"id": 2, "name": "Real Madrid"},
        }]})
        item = {
            "item_key": "name:kylian-mbappe|club:real-madrid",
            "reported_name": "Kylian Mbappé",
            "current_club_name": "Former Club",
            "destination_club_name": "Real Madrid",
            "aliases": [],
        }
        validated = validate_batch({"request_id": "run:destination", "players": [item]})[2][0]
        self.assertEqual("Real Madrid", validated["destination_club_name"])
        result = self.adapter.enrich(validated)
        self.assertEqual("fresh", result["status"])
        self.assertEqual("826643", result["identity"]["provider_player_id"])

    def test_former_club_history_recovers_one_exact_player_and_reuses_24h_cache(self):
        endpoint = "player/826643/transfer-history"
        self.transport.register(endpoint, {"transferHistory": [{
            "transferFrom": {"id": 1, "name": "Paris Saint-Germain"},
            "transferTo": {"id": 2, "name": "Real Madrid"},
        }]})
        item = {
            "item_key": "name:kylian-mbappé|club:paris-saint-germain",
            "reported_name": "Kylian Mbappé",
            "current_club_name": None,
            "former_club_name": "PSG",
            "former_club_aliases": ["PSG", "Paris Saint-Germain"],
            "aliases": [],
        }
        first = self.adapter.enrich(item)
        self.assertEqual("fresh", first["status"])
        self.assertEqual("826643", first["identity"]["provider_player_id"])
        self.assertEqual(80, first["identity"]["score"])
        self.assertEqual(1, [call["endpoint"] for call in self.transport.calls].count(endpoint))
        history_call = next(call for call in self.transport.calls if call["endpoint"] == endpoint)
        self.assertEqual(24 * 60 * 60, int(history_call["max_age"].total_seconds()))

        self.adapter.enrich(item)
        self.assertEqual(1, [call["endpoint"] for call in self.transport.calls].count(endpoint))

    def test_former_club_history_fetches_all_bounded_exact_candidates(self):
        search_endpoint = "search/all?q=Alex%20Smith"
        results = [{
            "type": "player",
            "entity": {
                "id": identifier,
                "name": "Alex Smith",
                "team": {"id": 100 + identifier, "name": f"Current {identifier}", "sport": {"slug": "football"}, "gender": "M"},
            },
        } for identifier in (1, 2, 3)]
        self.transport.register(search_endpoint, {"results": results})
        for identifier in (1, 2, 3):
            self.transport.register(f"player/{identifier}/transfer-history", {"transferHistory": [{
                "transferFrom": {"id": 9, "name": "Former FC" if identifier < 3 else "Other FC"},
                "transferTo": {"id": 10, "name": f"Current {identifier}"},
            }]})
        result = self.adapter.enrich({
            "item_key": "name:alex-smith|club:former",
            "reported_name": "Alex Smith",
            "former_club_name": "Former",
            "former_club_aliases": ["Former", "Former FC"],
            "aliases": [],
        })
        self.assertEqual("ambiguous", result["status"])
        self.assertEqual({"1", "2"}, {candidate["provider_player_id"] for candidate in result["candidates"]})
        self.assertEqual(3, sum("transfer-history" in call["endpoint"] for call in self.transport.calls))

    def test_former_club_history_none_over_cap_and_malformed_fail_closed(self):
        def result(identifier):
            return {"type": "player", "entity": {"id": identifier, "name": "Alex Smith", "team": {"id": 100 + identifier, "name": "Current", "sport": {"slug": "football"}, "gender": "M"}}}
        endpoint = "search/all?q=Alex%20Smith"
        self.transport.register(endpoint, {"results": [result(identifier) for identifier in (1, 2, 3, 4)]})
        item = {"item_key": "former", "reported_name": "Alex Smith", "former_club_name": "Former FC", "aliases": []}
        over_cap = self.adapter.enrich(item)
        self.assertEqual("ambiguous", over_cap["status"])
        self.assertEqual(0, sum("transfer-history" in call["endpoint"] for call in self.transport.calls))

        self.transport.calls.clear()
        malformed_endpoint = "search/all?q=Malformed%20Smith"
        malformed_result = result(1)
        malformed_result["entity"]["name"] = "Malformed Smith"
        self.transport.register(malformed_endpoint, {"results": [malformed_result]})
        self.transport.register("player/1/transfer-history", {"transferHistory": [{"transferFrom": {}, "transferTo": {"name": "Current"}}]})
        with self.assertRaises(SchemaError):
            self.adapter.enrich({**item, "reported_name": "Malformed Smith"})
        self.transport.register("player/1/transfer-history", {"transferHistory": [{
            "transferFrom": {"id": 1, "name": "Other FC"},
            "transferTo": {"id": 2, "name": "Current"},
        }]})
        corrected = self.adapter.enrich({**item, "reported_name": "Malformed Smith"})
        self.assertEqual("unresolved", corrected["status"])
        self.assertEqual(2, sum(call["endpoint"] == "player/1/transfer-history" for call in self.transport.calls))

    def test_mismatched_current_club_recovers_through_transfer_history(self):
        history_endpoint = "player/826643/transfer-history"
        self.transport.register(history_endpoint, {"transferHistory": [{
            "transferFrom": {"id": 1, "name": "Paris Saint-Germain"},
            "transferTo": {"id": 2, "name": "Real Madrid"},
        }]})
        result = self.adapter.enrich({
            "item_key": "explicit-current-conflict", "reported_name": "Kylian Mbappé",
            "current_club_name": "Wrong FC", "former_club_name": "Paris Saint-Germain",
            "former_club_aliases": ["PSG"], "aliases": [],
        })
        self.assertEqual("fresh", result["status"])
        self.assertEqual("826643", result["identity"]["provider_player_id"])
        self.assertEqual(80, result["identity"]["score"])
        self.assertTrue(any(call["endpoint"] == history_endpoint for call in self.transport.calls))

    def test_former_club_history_fetch_failure_is_not_a_non_match(self):
        self.transport.register("search/all?q=Failed%20Smith", {"results": [{
            "type": "player",
            "entity": {"id": 77, "name": "Failed Smith", "team": {"id": 7, "name": "Current", "sport": {"slug": "football"}, "gender": "M"}},
        }]})
        self.transport.register("player/77/transfer-history", RuntimeError("provider failed"))
        with self.assertRaisesRegex(RuntimeError, "provider failed"):
            self.adapter.enrich({
                "item_key": "failed-history", "reported_name": "Failed Smith",
                "former_club_name": "Former FC", "aliases": [],
            })

    def test_former_club_history_non_match_stays_unresolved(self):
        self.transport.register("search/all?q=No%20Match", {"results": [{
            "type": "player",
            "entity": {"id": 78, "name": "No Match", "team": {"id": 8, "name": "Current", "sport": {"slug": "football"}, "gender": "M"}},
        }]})
        self.transport.register("player/78/transfer-history", {"transferHistory": [{
            "transferFrom": {"id": 1, "name": "Other FC"},
            "transferTo": {"id": 8, "name": "Current"},
        }]})
        result = self.adapter.enrich({
            "item_key": "no-history-match", "reported_name": "No Match",
            "former_club_name": "Former FC", "aliases": [],
        })
        self.assertEqual("unresolved", result["status"])
        self.assertIsNone(result["identity"])
        self.assertEqual(2, result["provider_calls"])

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

    def test_statistics_connection_failure_keeps_profile_as_retryable_partial(self):
        statistics_endpoint = (
            "player/826643/unique-tournament/8/season/77559/statistics/overall"
        )
        self.transport.register(statistics_endpoint, ConnectionError("404 Not Found"))

        result = self.adapter.enrich(
            mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        )

        self.assertEqual("partial", result["status"])
        self.assertEqual("826643", result["identity"]["provider_player_id"])
        self.assertIsNotNone(result["profile"])
        self.assertIsNone(result["statistics"])
        self.assertEqual(
            [{"code": "statistics_unavailable", "retryable": True}],
            result["warnings"],
        )

    def test_validator_deduplicates_identical_items_and_rejects_conflicts(self):
        item = mapped_item("826643", "2829", "8", "77559", "Kylian Mbappé")
        item["allow_surname_only_match"] = True
        request_id, deadline_ms, players = validate_batch(
            {"request_id": "run:1", "players": [item, copy.deepcopy(item)]}
        )
        self.assertEqual("run:1", request_id)
        self.assertEqual(75_000, deadline_ms)
        self.assertEqual([item["item_key"]], [player["item_key"] for player in players])
        self.assertTrue(players[0]["allow_surname_only_match"])
        self.assertEqual([], players[0]["report_ids"])

        conflict = copy.deepcopy(item)
        conflict["reported_name"] = "Different"
        with self.assertRaisesRegex(ValueError, "duplicate item_key"):
            validate_batch({"request_id": "run:1", "players": [item, conflict]})

        invalid = copy.deepcopy(item)
        invalid["allow_surname_only_match"] = "true"
        with self.assertRaisesRegex(ValueError, "allow_surname_only_match"):
            validate_batch({"request_id": "run:1", "players": [invalid]})


if __name__ == "__main__":
    unittest.main()
