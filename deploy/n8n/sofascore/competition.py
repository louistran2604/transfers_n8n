from __future__ import annotations

import re
from datetime import datetime, timezone
from typing import Any


YEAR_RANGE = re.compile(r"^(?:(\d{2})/(\d{2})|(\d{4})/(\d{4}))$")


def validated_competition(
    player: dict[str, Any], metadata_payload: dict[str, Any]
) -> dict[str, str] | None:
    team = player.get("team")
    tournament = team.get("primaryUniqueTournament") if isinstance(team, dict) else None
    metadata = metadata_payload.get("uniqueTournament")
    if not isinstance(team, dict) or not isinstance(tournament, dict) or not isinstance(metadata, dict):
        return None
    team_sport = team.get("sport") or {}
    category = metadata.get("category") or {}
    category_sport = category.get("sport") or {}
    if (
        str(tournament.get("id", "")) != str(metadata.get("id", ""))
        or team_sport.get("slug") != "football"
        or category_sport.get("slug") != "football"
        or team.get("national") is not False
        or team.get("gender") not in (None, "M")
        or metadata.get("gender") not in (None, "M")
        or metadata.get("tier") not in (None, 1)
    ):
        return None
    profile_category = tournament.get("category") or {}
    if profile_category.get("alpha2") != category.get("alpha2"):
        return None
    return {
        "provider_unique_tournament_id": str(metadata["id"]),
        "name": str(metadata.get("name") or tournament.get("name") or ""),
    }


def _year_start(value: Any) -> int | None:
    if not isinstance(value, str):
        return None
    match = YEAR_RANGE.fullmatch(value.strip())
    if not match:
        return int(value) if value.isdigit() and len(value) == 4 else None
    if match.group(1) is not None:
        first = int(match.group(1))
        second = int(match.group(2))
        if second != (first + 1) % 100:
            return None
        return (1900 if first >= 70 else 2000) + first
    first = int(match.group(3))
    second = int(match.group(4))
    return first if second == first + 1 else None


def select_reporting_season(
    seasons_payload: dict[str, Any],
    metadata_payload: dict[str, Any],
    *,
    now: datetime | None = None,
) -> dict[str, str] | None:
    rows = seasons_payload.get("seasons")
    metadata = metadata_payload.get("uniqueTournament")
    if not isinstance(rows, list) or not rows or not isinstance(metadata, dict):
        return None
    parsed: list[tuple[int, dict[str, Any]]] = []
    ids: set[str] = set()
    for row in rows:
        if not isinstance(row, dict):
            return None
        identifier = str(row.get("id", ""))
        start_year = _year_start(row.get("year"))
        if not identifier.isdecimal() or identifier in ids or start_year is None:
            return None
        ids.add(identifier)
        parsed.append((start_year, row))
    if any(parsed[index][0] <= parsed[index + 1][0] for index in range(len(parsed) - 1)):
        return None

    now = now or datetime.now(timezone.utc)
    now_timestamp = int(now.timestamp())
    start_timestamp = metadata.get("startDateTimestamp")
    end_timestamp = metadata.get("endDateTimestamp")
    if (
        isinstance(start_timestamp, bool)
        or not isinstance(start_timestamp, int)
        or (
            end_timestamp is not None
            and (
                isinstance(end_timestamp, bool)
                or not isinstance(end_timestamp, int)
            )
        )
    ):
        return None
    try:
        current_year = datetime.fromtimestamp(start_timestamp, timezone.utc).year
        if end_timestamp is not None:
            datetime.fromtimestamp(end_timestamp, timezone.utc)
    except (OverflowError, OSError, ValueError):
        return None

    if start_timestamp > now_timestamp or (
        start_timestamp <= now_timestamp
        and (end_timestamp is None or now_timestamp <= end_timestamp)
    ):
        row = next((row for year, row in parsed if year < current_year), None)
    elif end_timestamp is not None and end_timestamp < now_timestamp:
        row = next((row for year, row in parsed if year <= current_year), None)
    else:
        return None
    if row is None:
        return None
    return {
        "provider_season_id": str(row["id"]),
        "label": str(row.get("year") or row.get("name")),
        "state": "latest_completed",
    }
