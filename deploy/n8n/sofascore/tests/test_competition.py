from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from competition import validated_competition


FIXTURES = Path(__file__).parent / "fixtures"


def profile_and_metadata(name: str) -> tuple[dict, dict]:
    bundle = json.loads((FIXTURES / name).read_text())
    profile = next(
        row["response"]["player"]
        for row in bundle["endpoints"]
        if row["endpoint"].startswith("player/") and row["endpoint"].count("/") == 1
    )
    metadata = next(
        row["response"]
        for row in bundle["endpoints"]
        if row["endpoint"].startswith("unique-tournament/")
        and row["endpoint"].count("/") == 1
    )
    return profile, metadata


class CompetitionTests(unittest.TestCase):
    def test_top_five_and_v_league_are_structurally_eligible(self):
        mbappe, laliga = profile_and_metadata("mbappe.json")
        quang_hai, v_league = profile_and_metadata("quang_hai.json")
        self.assertEqual("8", validated_competition(mbappe, laliga)["provider_unique_tournament_id"])
        self.assertEqual("626", validated_competition(quang_hai, v_league)["provider_unique_tournament_id"])

    def test_misleading_secondary_tournament_is_not_used(self):
        player, metadata = profile_and_metadata("quang_hai.json")
        player["team"]["tournament"] = {"id": 771, "name": "V-League 2"}
        result = validated_competition(player, metadata)
        self.assertEqual("626", result["provider_unique_tournament_id"])
        self.assertEqual("V-League 1", result["name"])

    def test_excluded_structures_fail_closed(self):
        player, metadata = profile_and_metadata("mbappe.json")
        mutations = [
            ("national team", lambda p, m: p["team"].update(national=True)),
            ("women", lambda p, m: p["team"].update(gender="F")),
            ("non-football", lambda p, m: m["uniqueTournament"]["category"]["sport"].update(slug="basketball")),
            ("lower tier", lambda p, m: m["uniqueTournament"].update(tier=2)),
            ("country mismatch", lambda p, m: m["uniqueTournament"]["category"].update(alpha2="FR")),
            ("identifier mismatch", lambda p, m: m["uniqueTournament"].update(id=17)),
        ]
        for label, mutate in mutations:
            with self.subTest(label=label):
                candidate = copy.deepcopy(player)
                candidate_metadata = copy.deepcopy(metadata)
                mutate(candidate, candidate_metadata)
                self.assertIsNone(validated_competition(candidate, candidate_metadata))

    def test_changed_primary_tournament_replaces_old_mapping_only_after_validation(self):
        player, metadata = profile_and_metadata("mbappe.json")
        old = validated_competition(player, metadata)
        promoted_player = copy.deepcopy(player)
        promoted_metadata = copy.deepcopy(metadata)
        promoted_player["team"]["primaryUniqueTournament"]["id"] = 17
        promoted_player["team"]["primaryUniqueTournament"]["name"] = "Premier League"
        promoted_player["team"]["primaryUniqueTournament"]["category"]["alpha2"] = "EN"
        promoted_metadata["uniqueTournament"].update(id=17, name="Premier League")
        promoted_metadata["uniqueTournament"]["category"]["alpha2"] = "EN"
        new = validated_competition(promoted_player, promoted_metadata)
        self.assertEqual("8", old["provider_unique_tournament_id"])
        self.assertEqual("17", new["provider_unique_tournament_id"])


if __name__ == "__main__":
    unittest.main()
