from __future__ import annotations

import json
import unittest
from datetime import datetime, timezone
from pathlib import Path

from identity import (
    accent_folded_key,
    manual_identity_decision,
    resolve_search,
    unicode_exact_key,
)


FIXTURES = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 7, 30, tzinfo=timezone.utc)


def search_payload(name: str) -> dict:
    bundle = json.loads((FIXTURES / name).read_text())
    return next(
        row["response"]
        for row in bundle["endpoints"]
        if row["endpoint"].startswith("search/")
    )


class IdentityTests(unittest.TestCase):
    def test_unicode_and_accent_keys_preserve_scripts_and_normalize_separators(self):
        self.assertEqual("kylian mbappé", unicode_exact_key("  KYLIAN—MBAPPÉ  "))
        self.assertEqual("kylian mbappe", accent_folded_key("Kylian Mbappé"))
        self.assertEqual("nguyễn quang hải", unicode_exact_key("Nguyễn　Quang Hải"))
        self.assertEqual("nguyen quang hai", accent_folded_key("Nguyễn Quang Hải"))

    def test_exact_name_requires_independent_team_discriminator(self):
        unresolved = resolve_search("Kylian Mbappé", search_payload("mbappe.json"))
        self.assertEqual("unresolved", unresolved["status"])
        self.assertEqual(50, unresolved["candidates"][0]["score"])

        resolved = resolve_search(
            "Kylian Mbappé",
            search_payload("mbappe.json"),
            provider_team_id="2829",
        )
        self.assertEqual("resolved", resolved["status"])
        self.assertGreaterEqual(resolved["identity"]["score"], 80)
        self.assertGreaterEqual(resolved["identity"]["margin"], 15)

    def test_soft_report_can_accept_one_exact_full_name_without_club_match(self):
        payload = {
            "results": [{
                "type": "player",
                "entity": {
                    "id": 826643,
                    "name": "Kylian Mbappé",
                    "team": {"id": 2829, "name": "Real Madrid", "sport": {"slug": "football"}, "gender": "M"},
                },
            }],
        }
        unresolved = resolve_search(
            "Kylian Mbappé", payload, reported_club_name="Atletico Madrid"
        )
        self.assertEqual("unresolved", unresolved["status"])
        resolved = resolve_search(
            "Kylian Mbappé",
            payload,
            reported_club_name="Atletico Madrid",
            allow_exact_name_without_club=True,
        )
        self.assertEqual("resolved", resolved["status"])
        self.assertEqual(50, resolved["identity"]["score"])

    def test_exact_reported_club_bootstraps_an_empty_identity_map(self):
        resolved = resolve_search(
            "Kylian Mbappé",
            search_payload("mbappe.json"),
            reported_club_name="Real Madrid",
        )
        self.assertEqual("resolved", resolved["status"])
        self.assertEqual("826643", resolved["identity"]["provider_player_id"])
        self.assertEqual(80, resolved["identity"]["score"])
        self.assertEqual(80, resolved["identity"]["margin"])

        mismatched = resolve_search(
            "Kylian Mbappé",
            search_payload("mbappe.json"),
            reported_club_name="Paris Saint-Germain",
        )
        self.assertEqual("unresolved", mismatched["status"])
        self.assertNotIn("identity", mismatched)

    def test_destination_club_and_safe_suffix_aliases_are_valid_discriminators(self):
        payload = {
            "results": [{
                "type": "player",
                "entity": {
                    "id": 826643,
                    "name": "Kylian Mbappé",
                    "team": {
                        "id": 2829,
                        "name": "Sporting CP",
                        "sport": {"slug": "football"},
                        "gender": "M",
                    },
                },
            }],
        }
        resolved = resolve_search(
            "Kylian Mbappé",
            payload,
            reported_club_names=["Former Club", "Sporting"],
        )
        self.assertEqual("resolved", resolved["status"])
        self.assertEqual("826643", resolved["identity"]["provider_player_id"])

    def test_speculative_destination_needs_history_confirmation_but_completed_moves_resolve(self):
        payload = {
            "results": [{
                "type": "player",
                "entity": {
                    "id": 826643,
                    "name": "Kylian Mbappé",
                    "team": {
                        "id": 2829,
                        "name": "Real Madrid",
                        "sport": {"slug": "football"},
                        "gender": "M",
                    },
                },
            }],
        }
        stale_current = resolve_search(
            "Kylian Mbappé",
            payload,
            reported_club_names=["Paris Saint-Germain"],
            destination_club_names=["Real Madrid"],
            destination_weight=20,
        )
        self.assertEqual("unresolved", stale_current["status"])
        self.assertEqual(70, stale_current["candidates"][0]["score"])

        completed = resolve_search(
            "Kylian Mbappé",
            payload,
            reported_club_names=["Paris Saint-Germain"],
            destination_club_names=["Real Madrid"],
            destination_weight=30,
        )
        self.assertEqual("resolved", completed["status"])
        self.assertEqual(80, completed["identity"]["score"])

    def test_destination_evidence_cannot_outvote_current_club_matches(self):
        payload = {
            "results": [
                {
                    "type": "player",
                    "entity": {
                        "id": 1,
                        "name": "Kylian Mbappé",
                        "team": {"id": 1, "name": "Real Madrid", "sport": {"slug": "football"}, "gender": "M"},
                    },
                },
                {
                    "type": "player",
                    "entity": {
                        "id": 2,
                        "name": "Kylian Mbappé",
                        "team": {"id": 2, "name": "Other FC", "sport": {"slug": "football"}, "gender": "M"},
                    },
                },
            ],
        }
        for destination_weight in (20, 30):
            with self.subTest(destination_weight=destination_weight):
                result = resolve_search(
                    "Kylian Mbappé",
                    payload,
                    reported_club_names=["Real Madrid"],
                    destination_club_names=["Other FC"],
                    destination_weight=destination_weight,
                )
                self.assertEqual("ambiguous", result["status"])
                self.assertIsNone(result.get("identity"))

    def test_only_curated_club_variants_bridge_provider_names(self):
        cases = [
            ("Barcelona", "FC Barcelona"),
            ("Napoli", "SSC Napoli"),
            ("Marseille", "Olympique de Marseille"),
        ]
        for reported, provider in cases:
            with self.subTest(reported=reported):
                payload = {
                    "results": [{
                        "type": "player",
                        "entity": {
                            "id": 10,
                            "name": "Test Player",
                            "team": {"id": 20, "name": provider, "sport": {"slug": "football"}, "gender": "M"},
                        },
                    }],
                }
                result = resolve_search(
                    "Test Player",
                    payload,
                    reported_club_name=reported,
                    reported_club_names=[reported, provider],
                )
                self.assertEqual("resolved", result["status"])

        unknown = resolve_search(
            "Test Player",
            {"results": [{"type": "player", "entity": {"id": 10, "name": "Test Player", "team": {"id": 20, "name": "Olympique Lyonnais", "sport": {"slug": "football"}, "gender": "M"}}}]},
            reported_club_name="Olympique de Marseille",
            reported_club_names=["Marseille", "Olympique de Marseille"],
        )
        self.assertEqual("unresolved", unknown["status"])

    def test_porto_curated_variant_resolves_but_generic_porto_stays_ambiguous(self):
        payload = {
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
        }
        generic = resolve_search("Rodrigo Mora", payload, reported_club_name="Porto")
        self.assertEqual("ambiguous", generic["status"])
        self.assertNotIn("identity", generic)

        curated = resolve_search(
            "Rodrigo Mora",
            payload,
            reported_club_name="Porto",
            reported_club_names=["Porto", "FC Porto"],
        )
        self.assertEqual("resolved", curated["status"])
        self.assertEqual("1410240", curated["identity"]["provider_player_id"])
        self.assertEqual(80, curated["identity"]["score"])
        self.assertEqual(30, curated["identity"]["margin"])

    def test_al_hilal_punctuation_normalization_is_generic(self):
        payload = {
            "results": [{
                "type": "player",
                "entity": {
                    "id": 1,
                    "name": "Test Player",
                    "team": {"id": 2, "name": "Al-Hilal", "sport": {"slug": "football"}, "gender": "M"},
                },
            }]
        }
        result = resolve_search("Test Player", payload, reported_club_name="Al Hilal")
        self.assertEqual("resolved", result["status"])
        self.assertEqual("1", result["identity"]["provider_player_id"])
        self.assertEqual(80, result["identity"]["score"])

    def test_duplicate_exact_names_are_ambiguous_and_bounded(self):
        result = resolve_search("John Smith", search_payload("john_smith.json"))
        self.assertEqual("ambiguous", result["status"])
        self.assertLessEqual(len(result["candidates"]), 5)
        self.assertEqual(
            {"2544168", "2332241"},
            {candidate["provider_player_id"] for candidate in result["candidates"]},
        )

        mismatched = resolve_search(
            "John Smith",
            search_payload("john_smith.json"),
            reported_club_name="Unrelated FC",
        )
        self.assertEqual("ambiguous", mismatched["status"])
        self.assertNotIn("identity", mismatched)

    def test_explicit_alias_can_resolve_but_fuzzy_name_cannot(self):
        payload = search_payload("mbappe.json")
        aliased = resolve_search(
            "Kylian Mbappe",
            payload,
            aliases=["Kylian Mbappé"],
            provider_team_id="2829",
        )
        self.assertEqual("resolved", aliased["status"])

        fuzzy = resolve_search(
            "Kylian Mbap",
            payload,
            provider_team_id="2829",
        )
        self.assertEqual("unresolved", fuzzy["status"])

    def test_curated_name_and_club_aliases_resolve_without_fuzzy_expansion(self):
        payload = {
            "results": [{
                "type": "player",
                "entity": {
                    "id": 1001,
                    "name": "Destiny Udogie",
                    "team": {
                        "id": 2001,
                        "name": "Royale Union Saint-Gilloise",
                        "sport": {"slug": "football"},
                        "gender": "M",
                    },
                },
            }]
        }
        resolved = resolve_search(
            "Destiny Udogie",
            payload,
            aliases=["Udogie"],
            reported_club_name="Union Saint-Gilloise",
            reported_club_names=[
                "Union Saint-Gilloise",
                "Royale Union Saint-Gilloise",
            ],
        )
        self.assertEqual("resolved", resolved["status"])
        self.assertEqual(80, resolved["identity"]["score"])
        self.assertEqual(80, resolved["identity"]["margin"])

        surname_only = resolve_search(
            "Udogie",
            payload,
            reported_club_names=["Royale Union Saint-Gilloise"],
        )
        self.assertEqual("unresolved", surname_only["status"])
        self.assertEqual([], surname_only["candidates"])

        leading_word = resolve_search(
            "Destiny",
            payload,
            reported_club_names=["Royale Union Saint-Gilloise"],
        )
        self.assertEqual("unresolved", leading_word["status"])
        self.assertEqual([], leading_word["candidates"])

    def test_non_common_surname_can_use_a_matching_club_discriminator(self):
        payload = {
            "results": [
                {
                    "type": "player",
                    "entity": {
                        "id": 1140599,
                        "name": "Jamie Gittens",
                        "team": {
                            "id": 38,
                            "name": "Chelsea",
                            "sport": {"slug": "football"},
                            "gender": "M",
                        },
                    },
                },
                {
                    "type": "player",
                    "entity": {
                        "id": 1140600,
                        "name": "Jamal Gittens",
                        "team": {
                            "id": 39,
                            "name": "Other FC",
                            "sport": {"slug": "football"},
                            "gender": "M",
                        },
                    },
                },
            ],
        }
        without_opt_in = resolve_search("Gittens", payload, reported_club_name="Chelsea")
        self.assertEqual("unresolved", without_opt_in["status"])
        self.assertEqual([], without_opt_in["candidates"])

        resolved = resolve_search(
            "Gittens",
            payload,
            reported_club_name="Chelsea",
            allow_surname_only_match=True,
        )
        self.assertEqual("resolved", resolved["status"])
        self.assertEqual("1140599", resolved["identity"]["provider_player_id"])
        self.assertEqual(80, resolved["identity"]["score"])
        self.assertEqual(30, resolved["identity"]["margin"])

        mismatched = resolve_search(
            "Gittens",
            payload,
            reported_club_name="Roma",
            allow_surname_only_match=True,
        )
        self.assertEqual("ambiguous", mismatched["status"])
        self.assertNotIn("identity", mismatched)

    def test_curated_romero_and_club_scoped_lukaku_requests_resolve_live_cache_shapes(self):
        def payload(identifier: int, player: str, club: str) -> dict:
            return {"results": [{"type": "player", "entity": {
                "id": identifier,
                "name": player,
                "team": {"id": identifier + 1, "name": club, "sport": {"slug": "football"}, "gender": "M"},
            }}]}

        cuti = resolve_search(
            "Cristian Romero",
            payload(829932, "Cristian Romero", "Tottenham Hotspur"),
            aliases=["Cuti Romero"],
            reported_club_name="Tottenham Hotspur",
            reported_club_names=["Tottenham Hotspur", "Tottenham"],
        )
        self.assertEqual("829932", cuti["identity"]["provider_player_id"])

        lukaku = resolve_search(
            "Romelu Lukaku",
            payload(78893, "Romelu Lukaku", "SSC Napoli"),
            aliases=["Lukaku"],
            reported_club_name="Napoli",
            reported_club_names=["Napoli", "SSC Napoli", "sscnapoli"],
        )
        self.assertEqual("78893", lukaku["identity"]["provider_player_id"])

        unrelated = resolve_search(
            "Lukaku",
            payload(78893, "Romelu Lukaku", "SSC Napoli"),
            reported_club_name="Roma",
            reported_club_names=["Roma"],
        )
        self.assertEqual("unresolved", unrelated["status"])
        self.assertEqual([], unrelated["candidates"])

    def test_nonfootball_women_youth_and_rejected_candidates_are_excluded(self):
        payload = {
            "results": [
                {
                    "type": "player",
                    "entity": {
                        "id": identifier,
                        "name": "Alex Smith",
                        "team": team,
                    },
                }
                for identifier, team in (
                    (1, {"sport": {"slug": "basketball"}, "name": "Club"}),
                    (2, {"sport": {"slug": "football"}, "gender": "F", "name": "Club"}),
                    (3, {"sport": {"slug": "football"}, "name": "Club U21"}),
                    (4, {"sport": {"slug": "football"}, "gender": "M", "id": 9, "name": "Club"}),
                )
            ]
        }
        result = resolve_search(
            "Alex Smith",
            payload,
            provider_team_id="9",
            rejected_player_ids={"4"},
        )
        self.assertEqual("unresolved", result["status"])
        self.assertEqual([], result["candidates"])

    def test_manual_override_precedence_expiry_rejection_and_conflict(self):
        base = {
            "active": True,
            "effective_from": "2026-01-01T00:00:00Z",
            "effective_until": "2027-01-01T00:00:00Z",
        }
        self.assertEqual(
            {"action": "resolve", "provider_player_id": "826643"},
            manual_identity_decision(
                [{**base, "action": "resolve", "provider_player_id": "826643"}],
                now=NOW,
            ),
        )
        self.assertEqual(
            {"action": "reject_all"},
            manual_identity_decision([{**base, "action": "reject_all"}], now=NOW),
        )
        self.assertEqual(
            {"action": "reject", "provider_player_ids": {"826643"}},
            manual_identity_decision(
                [{**base, "action": "reject", "provider_player_id": "826643"}],
                now=NOW,
            ),
        )
        self.assertEqual(
            {"action": "conflict"},
            manual_identity_decision(
                [
                    {**base, "action": "resolve", "provider_player_id": "1"},
                    {**base, "action": "resolve", "provider_player_id": "2"},
                ],
                now=NOW,
            ),
        )
        self.assertIsNone(
            manual_identity_decision(
                [
                    {
                        **base,
                        "action": "resolve",
                        "provider_player_id": "826643",
                        "effective_until": "2026-07-01T00:00:00Z",
                    }
                ],
                now=NOW,
            )
        )


if __name__ == "__main__":
    unittest.main()
