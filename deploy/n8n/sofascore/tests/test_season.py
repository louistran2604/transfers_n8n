from __future__ import annotations

import copy
import json
import unittest
from datetime import datetime, timezone
from pathlib import Path

from competition import select_reporting_season


FIXTURES = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 7, 30, tzinfo=timezone.utc)


def season_data() -> tuple[dict, dict]:
    bundle = json.loads((FIXTURES / "mbappe.json").read_text())
    seasons = next(
        row["response"]
        for row in bundle["endpoints"]
        if row["endpoint"] == "unique-tournament/8/seasons"
    )
    metadata = next(
        row["response"]
        for row in bundle["endpoints"]
        if row["endpoint"] == "unique-tournament/8"
    )
    return seasons, metadata


class SeasonTests(unittest.TestCase):
    def test_future_first_entry_is_skipped_using_metadata(self):
        seasons, metadata = season_data()
        selected = select_reporting_season(seasons, metadata, now=NOW)
        self.assertEqual("77559", selected["provider_season_id"])
        self.assertEqual("25/26", selected["label"])
        self.assertEqual("latest_completed", selected["state"])

    def test_historical_two_and_four_digit_ranges_keep_future_first_selection(self):
        seasons, metadata = season_data()
        seasons = copy.deepcopy(seasons)
        seasons["seasons"].extend([
            {"id": 9900, "year": "99/00"},
            {"id": 196970, "year": "1969/1970"},
        ])
        selected = select_reporting_season(seasons, metadata, now=NOW)
        self.assertEqual("77559", selected["provider_season_id"])
        self.assertEqual("25/26", selected["label"])
        self.assertEqual("latest_completed", selected["state"])

    def test_started_not_ended_season_uses_latest_completed(self):
        seasons, metadata = season_data()
        metadata = copy.deepcopy(metadata)
        metadata["uniqueTournament"]["startDateTimestamp"] = int(
            datetime(2026, 7, 1, tzinfo=timezone.utc).timestamp()
        )
        metadata["uniqueTournament"]["endDateTimestamp"] = int(
            datetime(2027, 5, 30, tzinfo=timezone.utc).timestamp()
        )
        selected = select_reporting_season(seasons, metadata, now=NOW)
        self.assertEqual("77559", selected["provider_season_id"])
        self.assertEqual("latest_completed", selected["state"])

    def test_reversed_duplicate_unparseable_and_missing_seasons_fail_closed(self):
        seasons, metadata = season_data()
        variants = []
        reversed_rows = copy.deepcopy(seasons)
        reversed_rows["seasons"][:2] = reversed(reversed_rows["seasons"][:2])
        variants.append(reversed_rows)
        duplicate = copy.deepcopy(seasons)
        duplicate["seasons"][1]["id"] = duplicate["seasons"][0]["id"]
        variants.append(duplicate)
        unparseable = copy.deepcopy(seasons)
        unparseable["seasons"][0]["year"] = "future"
        variants.append(unparseable)
        for year in ("26/28", "2026/2028", "2026/27"):
            nonconsecutive = copy.deepcopy(seasons)
            nonconsecutive["seasons"][0]["year"] = year
            variants.append(nonconsecutive)
        variants.extend([{"seasons": []}, {"unexpected": []}])
        for variant in variants:
            with self.subTest(variant=variant):
                self.assertIsNone(select_reporting_season(variant, metadata, now=NOW))

    def test_single_future_season_has_no_reporting_fallback(self):
        seasons, metadata = season_data()
        only_future = {"seasons": [seasons["seasons"][0]]}
        self.assertIsNone(select_reporting_season(only_future, metadata, now=NOW))


if __name__ == "__main__":
    unittest.main()
