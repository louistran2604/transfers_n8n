from __future__ import annotations

import unicodedata
from datetime import datetime, timezone
from typing import Any

from models import DECIMAL_ID


RESOLVER_VERSION = "identity-v1"
NON_DISCRIMINATING_CLUB_KEYS = {
    "",
    "free agent",
    "no team",
    "not reported",
    "n a",
    "unattached",
    "unknown",
}
CLUB_SUFFIXES = {"afc", "cf", "cp", "fc", "sc"}


def unicode_exact_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    characters = [
        " " if unicodedata.category(character)[0] in {"P", "Z"} else character
        for character in normalized
    ]
    return " ".join("".join(characters).split())


def accent_folded_key(value: str) -> str:
    return "".join(
        character
        for character in unicodedata.normalize("NFKD", unicode_exact_key(value))
        if not unicodedata.combining(character)
    )


def known_identity(provider_player_id: str) -> dict[str, Any]:
    return {
        "provider": "sofascore",
        "provider_player_id": provider_player_id,
        "stable_source_identifier": f"sofascore:player:{provider_player_id}",
        "score": 80,
        "margin": 80,
        "resolver_version": RESOLVER_VERSION,
    }


def manual_identity_decision(
    overrides: list[Any], *, now: datetime | None = None
) -> dict[str, Any] | None:
    now = now or datetime.now(timezone.utc)
    active: list[dict[str, Any]] = []
    for override in overrides:
        if not isinstance(override, dict) or override.get("active") is False:
            continue
        if override.get("revoked_at"):
            continue
        try:
            effective_from = _timestamp(override.get("effective_from"))
            effective_until = _timestamp(override.get("effective_until"))
        except ValueError:
            continue
        if effective_from and now < effective_from:
            continue
        if effective_until and now >= effective_until:
            continue
        if override.get("action") in {"resolve", "reject", "reject_all"}:
            active.append(override)
    if not active:
        return None
    reject_all = next(
        (override for override in active if override["action"] == "reject_all"), None
    )
    if reject_all:
        return {"action": "reject_all"}
    resolved = {
        str(override.get("provider_player_id"))
        for override in active
        if override["action"] == "resolve"
        and DECIMAL_ID.fullmatch(str(override.get("provider_player_id", "")))
    }
    if len(resolved) > 1:
        return {"action": "conflict"}
    rejected = {
        str(override.get("provider_player_id"))
        for override in active
        if override["action"] == "reject"
        and DECIMAL_ID.fullmatch(str(override.get("provider_player_id", "")))
    }
    if resolved:
        return {"action": "resolve", "provider_player_id": resolved.pop()}
    return {"action": "reject", "provider_player_ids": rejected}


def _timestamp(value: Any) -> datetime | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError("timestamp must be a string")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _football_player(entry: Any) -> bool:
    if not isinstance(entry, dict) or entry.get("type") != "player":
        return False
    entity = entry.get("entity")
    if not isinstance(entity, dict) or not DECIMAL_ID.fullmatch(str(entity.get("id", ""))):
        return False
    team = entity.get("team")
    if not isinstance(team, dict):
        return False
    sport = team.get("sport")
    if not isinstance(sport, dict) or sport.get("slug") != "football":
        return False
    if team.get("gender") == "F":
        return False
    team_name = unicode_exact_key(str(team.get("name", "")))
    return not any(marker in team_name.split() for marker in ("women", "u17", "u19", "u21", "u23"))


def _reported_club_matches(reported_club_name: Any, team: dict[str, Any]) -> bool:
    if not isinstance(reported_club_name, str) or not isinstance(team.get("name"), str):
        return False
    reported_exact = unicode_exact_key(reported_club_name)
    candidate_exact = unicode_exact_key(team["name"])
    if (
        reported_exact in NON_DISCRIMINATING_CLUB_KEYS
        or candidate_exact in NON_DISCRIMINATING_CLUB_KEYS
    ):
        return False
    candidate_folded = accent_folded_key(team["name"])
    reported_folded = accent_folded_key(reported_club_name)
    if candidate_exact == reported_exact or candidate_folded == reported_folded:
        return True
    candidate_parts = candidate_folded.split()
    reported_parts = reported_folded.split()
    if candidate_parts and candidate_parts[-1] in CLUB_SUFFIXES:
        candidate_parts.pop()
    if reported_parts and reported_parts[-1] in CLUB_SUFFIXES:
        reported_parts.pop()
    return bool(candidate_parts and candidate_parts == reported_parts)


def resolve_search(
    reported_name: str,
    search_payload: dict[str, Any],
    *,
    aliases: list[str] | None = None,
    provider_team_id: str | None = None,
    reported_club_name: str | None = None,
    reported_club_names: list[str] | None = None,
    rejected_player_ids: set[str] | None = None,
) -> dict[str, Any]:
    exact = unicode_exact_key(reported_name)
    folded = accent_folded_key(reported_name)
    alias_keys = {unicode_exact_key(alias) for alias in aliases or []}
    candidates: list[dict[str, Any]] = []

    results = search_payload.get("results")
    if not isinstance(results, list):
        raise ValueError("invalid search envelope")
    for entry in results:
        if not _football_player(entry):
            continue
        entity = entry["entity"]
        if str(entity["id"]) in (rejected_player_ids or set()):
            continue
        candidate_name = str(entity.get("name", ""))
        candidate_exact = unicode_exact_key(candidate_name)
        candidate_folded = accent_folded_key(candidate_name)
        if candidate_exact == exact or candidate_folded == folded:
            score = 50
        elif candidate_exact in alias_keys:
            score = 45
        else:
            continue
        team = entity.get("team") or {}
        club_names = [
            club_name
            for club_name in [reported_club_name, *(reported_club_names or [])]
            if isinstance(club_name, str)
        ]
        team_discriminator_matches = (
            str(team.get("id", "")) == provider_team_id
            if provider_team_id
            else any(_reported_club_matches(club_name, team) for club_name in club_names)
        )
        if team_discriminator_matches:
            score += 30
        candidates.append(
            {
                "provider_player_id": str(entity["id"]),
                "canonical_name": candidate_name,
                "score": score,
            }
        )

    candidates.sort(key=lambda candidate: (-candidate["score"], int(candidate["provider_player_id"])))
    if not candidates:
        return {"status": "unresolved", "candidates": []}
    best = candidates[0]
    margin = best["score"] - (candidates[1]["score"] if len(candidates) > 1 else 0)
    if best["score"] < 80:
        status = "ambiguous" if len(candidates) > 1 and margin < 15 else "unresolved"
        return {"status": status, "candidates": candidates[:5]}
    if margin < 15:
        return {"status": "ambiguous", "candidates": candidates[:5]}
    identity = known_identity(best["provider_player_id"])
    identity.update(score=best["score"], margin=margin)
    return {"status": "resolved", "identity": identity, "candidates": candidates[:5]}
