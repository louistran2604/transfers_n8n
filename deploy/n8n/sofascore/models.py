from __future__ import annotations

import re
from typing import Any


DECIMAL_ID = re.compile(r"^\d+$")
MAX_BATCH_SIZE = 25
MAX_DEADLINE_MS = 75_000


def decimal_id(value: Any, field: str, *, required: bool = False) -> str | None:
    if value is None and not required:
        return None
    if not isinstance(value, str) or not DECIMAL_ID.fullmatch(value):
        raise ValueError(f"{field} must be a decimal string")
    return value


def optional_string(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{field} must be a string or null")
    value = value.strip()
    return value or None


def validate_player(value: Any, index: int) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError(f"players[{index}] must be an object")
    item_key = optional_string(value.get("item_key"), f"players[{index}].item_key")
    reported_name = optional_string(value.get("reported_name"), f"players[{index}].reported_name")
    if not item_key or not reported_name:
        raise ValueError(f"players[{index}] requires item_key and reported_name")

    normalized = dict(value)
    normalized["item_key"] = item_key
    normalized["reported_name"] = reported_name
    for club_field in ("current_club_name", "former_club_name", "destination_club_name"):
        if club_field in value:
            normalized[club_field] = optional_string(
                value.get(club_field),
                f"players[{index}].{club_field}",
            )
    normalized["known_provider_player_id"] = decimal_id(
        value.get("known_provider_player_id"),
        f"players[{index}].known_provider_player_id",
    )
    report_ids = value.get("report_ids", [])
    if not isinstance(report_ids, list) or any(
        not isinstance(item, str) or not item for item in report_ids
    ):
        raise ValueError(f"players[{index}].report_ids must be an array of strings")
    aliases = value.get("aliases", [])
    if not isinstance(aliases, list) or any(
        not isinstance(item, str) or not item.strip() for item in aliases
    ):
        raise ValueError(f"players[{index}].aliases must be an array of strings")
    normalized["report_ids"] = report_ids
    normalized["aliases"] = aliases
    for alias_field in (
        "current_club_aliases",
        "former_club_aliases",
        "destination_club_aliases",
    ):
        club_aliases = value.get(alias_field, [])
        if not isinstance(club_aliases, list) or any(
            not isinstance(item, str) or not item.strip() for item in club_aliases
        ):
            raise ValueError(f"players[{index}].{alias_field} must be an array of strings")
        normalized[alias_field] = club_aliases

    for mapping_name, id_fields in (
        ("team_mapping", ("provider_team_id", "provider_unique_tournament_id")),
        ("season_mapping", ("provider_season_id",)),
    ):
        mapping = value.get(mapping_name)
        if mapping is None:
            continue
        if not isinstance(mapping, dict):
            raise ValueError(f"players[{index}].{mapping_name} must be an object or null")
        mapping = dict(mapping)
        for field in id_fields:
            mapping[field] = decimal_id(
                mapping.get(field),
                f"players[{index}].{mapping_name}.{field}",
                required=True,
            )
        normalized[mapping_name] = mapping
    return normalized


def validate_batch(value: Any) -> tuple[str, int, list[dict[str, Any]]]:
    if not isinstance(value, dict):
        raise ValueError("request body must be an object")
    request_id = optional_string(value.get("request_id"), "request_id")
    if not request_id:
        raise ValueError("request_id is required")
    deadline_ms = value.get("deadline_ms", MAX_DEADLINE_MS)
    if (
        isinstance(deadline_ms, bool)
        or not isinstance(deadline_ms, int)
        or not 1 <= deadline_ms <= MAX_DEADLINE_MS
    ):
        raise ValueError(f"deadline_ms must be an integer from 1 to {MAX_DEADLINE_MS}")
    players = value.get("players")
    if not isinstance(players, list) or not players:
        raise ValueError("players must be a non-empty array")
    if len(players) > MAX_BATCH_SIZE:
        raise OverflowError(f"players must contain at most {MAX_BATCH_SIZE} entries")

    deduplicated: dict[str, dict[str, Any]] = {}
    for index, player in enumerate(players):
        normalized = validate_player(player, index)
        previous = deduplicated.get(normalized["item_key"])
        if previous is not None and previous != normalized:
            raise ValueError("duplicate item_key entries must be identical")
        deduplicated[normalized["item_key"]] = normalized
    return request_id, deadline_ms, list(deduplicated.values())


def nullable_int(value: Any) -> int | None:
    return value if isinstance(value, int) and not isinstance(value, bool) else None


def nullable_float(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value)
