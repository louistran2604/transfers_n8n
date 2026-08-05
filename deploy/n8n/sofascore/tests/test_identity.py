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
