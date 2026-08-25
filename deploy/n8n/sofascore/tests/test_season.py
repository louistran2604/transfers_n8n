from __future__ import annotations

import copy
import json
import unittest
from datetime import datetime, timezone
from pathlib import Path

from competition import select_reporting_season


FIXTURES = Path(__file__).parent / "fixtures"
NOW = datetime(2026, 7, 30, tzinfo=timezone.utc)


def listed_seasons(*labels: str) -> dict:
    return {
        "seasons": [
            {"id": str(index), "year": label}
            for index, label in enumerate(labels, start=1)
        ]
    }


def tournament_metadata(start: datetime, end: datetime | None) -> dict:
    return {
        "uniqueTournament": {
            "startDateTimestamp": int(start.timestamp()),
            "endDateTimestamp": int(end.timestamp()) if end is not None else None,
        }
    }


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

    def test_prelisted_next_season_during_active_current_season_selects_previous(self):
        seasons = listed_seasons("26/27", "25/26", "24/25")
        metadata = tournament_metadata(
            datetime(2025, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 6, 1, tzinfo=timezone.utc),
        )
        selected = select_reporting_season(
            seasons, metadata, now=datetime(2026, 4, 1, tzinfo=timezone.utc)
        )
        self.assertEqual("3", selected["provider_season_id"])
        self.assertEqual("24/25", selected["label"])

    def test_ended_metadata_with_prelisted_newer_season_selects_ended_season(self):
        seasons = listed_seasons("25/26", "24/25", "23/24")
        metadata = tournament_metadata(
            datetime(2024, 8, 1, tzinfo=timezone.utc),
            datetime(2025, 6, 1, tzinfo=timezone.utc),
        )
        selected = select_reporting_season(
            seasons, metadata, now=datetime(2025, 7, 1, tzinfo=timezone.utc)
        )
        self.assertEqual("2", selected["provider_season_id"])
        self.assertEqual("24/25", selected["label"])

    def test_calendar_year_active_and_ended_metadata_select_previous_completed_year(self):
        seasons = listed_seasons("2026", "2025", "2024")
        cases = (
            (
                datetime(2026, 1, 1, tzinfo=timezone.utc),
                datetime(2026, 12, 31, tzinfo=timezone.utc),
                datetime(2026, 6, 1, tzinfo=timezone.utc),
            ),
            (
                datetime(2025, 1, 1, tzinfo=timezone.utc),
                datetime(2025, 12, 31, tzinfo=timezone.utc),
                datetime(2026, 1, 1, tzinfo=timezone.utc),
            ),
        )
        for start, end, now in cases:
            with self.subTest(now=now):
                selected = select_reporting_season(
                    seasons, tournament_metadata(start, end), now=now
                )
                self.assertEqual("2", selected["provider_season_id"])
                self.assertEqual("2025", selected["label"])

    def test_ended_current_season_is_selected_after_scheduled_end(self):
        seasons = listed_seasons("25/26", "24/25")
        metadata = tournament_metadata(
            datetime(2025, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 6, 1, tzinfo=timezone.utc),
        )
        selected = select_reporting_season(seasons, metadata, now=NOW)
        self.assertEqual("1", selected["provider_season_id"])
        self.assertEqual("25/26", selected["label"])

    def test_missing_or_unusable_metadata_timestamps_fail_closed(self):
        seasons = listed_seasons("26/27", "25/26")
        variants = [
            {},
            {"startDateTimestamp": None, "endDateTimestamp": 1},
            {"startDateTimestamp": "not-a-timestamp", "endDateTimestamp": 1},
            {"startDateTimestamp": 1, "endDateTimestamp": "not-a-timestamp"},
        ]
        for timestamps in variants:
            with self.subTest(timestamps=timestamps):
                metadata = {"uniqueTournament": timestamps}
                self.assertIsNone(select_reporting_season(seasons, metadata, now=NOW))

    def test_missing_end_timestamp_is_treated_as_active(self):
        seasons = listed_seasons("26/27", "25/26", "24/25")
        metadata = tournament_metadata(
            datetime(2025, 8, 1, tzinfo=timezone.utc), None
        )
        selected = select_reporting_season(
            seasons, metadata, now=datetime(2026, 4, 1, tzinfo=timezone.utc)
        )
        self.assertEqual("3", selected["provider_season_id"])

    def test_no_row_satisfies_phase_predicate(self):
        seasons = listed_seasons("26/27", "25/26")
        metadata = tournament_metadata(
            datetime(2025, 8, 1, tzinfo=timezone.utc),
            datetime(2026, 6, 1, tzinfo=timezone.utc),
        )
        self.assertIsNone(
            select_reporting_season(
                seasons,
                metadata,
                now=datetime(2026, 4, 1, tzinfo=timezone.utc),
            )
        )


if __name__ == "__main__":
    unittest.main()
