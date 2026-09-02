from __future__ import annotations

import hashlib
import io
import json
import math
import os
import random
import re
import signal
import time
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable
from urllib.parse import quote

from competition import select_reporting_season, validated_competition
from identity import (
    RESOLVER_VERSION,
    _reported_club_matches,
    exact_name_candidates,
    is_discriminating_club_name,
    known_identity,
    manual_identity_decision,
    resolve_search,
    transfer_history_matches_club,
)
from models import nullable_float, nullable_int, optional_as_of_date


API_ROOT = "https://api.sofascore.com/api/v1/"
ADAPTER_SCHEMA = "sofascore-player-v1"
STATISTICS_SELECTOR_VERSION = "statistics-v2"
POSITION_NAMES = {"F": "Forward", "M": "Midfielder", "D": "Defender", "G": "Goalkeeper"}


class ProviderError(RuntimeError):
    pass


class SchemaError(ProviderError):
    pass


def nonnegative_int(value: Any) -> int | None:
    normalized = nullable_int(value)
    return normalized if normalized is not None and normalized >= 0 else None


def nonnegative_float(value: Any) -> float | None:
    normalized = nullable_float(value)
    return (
        normalized
        if normalized is not None and math.isfinite(normalized) and normalized >= 0
        else None
    )


@contextmanager
def call_deadline(seconds: float):
    if seconds <= 0 or not hasattr(signal, "setitimer"):
        yield
        return

    def expire(_signum: int, _frame: Any) -> None:
        raise TimeoutError("provider call timed out")

    previous = signal.signal(signal.SIGALRM, expire)
    signal.setitimer(signal.ITIMER_REAL, seconds)
    try:
        yield
    finally:
        signal.setitimer(signal.ITIMER_REAL, 0)
        signal.signal(signal.SIGALRM, previous)


def create_reader(cache_dir: Path) -> Any:
    import soccerdata
    from soccerdata import Sofascore

    if soccerdata.__version__ != "1.9.1":
        raise RuntimeError("soccerdata 1.9.1 is required")
    return Sofascore(leagues=None, seasons=None, data_dir=cache_dir)


class SofascoreAdapter:
    def __init__(
        self,
        reader: Any,
        cache_dir: Path,
        *,
        call_timeout_seconds: float = 15,
        min_interval_seconds: float = 1,
        jitter_seconds: float = 0.25,
        profile_max_age_hours: float = 24,
        stats_max_age_hours: float = 12,
        mapping_max_age_hours: float = 24,
        now: Callable[[], datetime] | None = None,
    ):
        self.reader = reader
        self.cache_dir = cache_dir
        self.call_timeout_seconds = call_timeout_seconds
        self.min_interval_seconds = min_interval_seconds
        self.jitter_seconds = jitter_seconds
        self.profile_max_age_hours = profile_max_age_hours
        self.stats_max_age_hours = stats_max_age_hours
        self.mapping_max_age_hours = mapping_max_age_hours
        self.now = now or (lambda: datetime.now(timezone.utc))
        self._last_call_at = 0.0
        self._last_good: dict[str, dict[str, Any]] = {}
        self._mapping_cache: dict[str, tuple[datetime, dict[str, Any]]] = {}
        self.provider_calls = 0

    def _pace(self) -> None:
        delay = self.min_interval_seconds - (time.monotonic() - self._last_call_at)
        if self.jitter_seconds:
            delay += random.uniform(0, self.jitter_seconds)
        if delay > 0:
            time.sleep(delay)

    @staticmethod
    def _parse_response(response: Any) -> dict[str, Any]:
        value = response.read() if hasattr(response, "read") else response
        if isinstance(value, str):
            value = value.encode()
        if not isinstance(value, bytes):
            raise SchemaError("provider response must be bytes")
        try:
            payload = json.loads(value)
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SchemaError("provider response is not valid JSON") from error
        if not isinstance(payload, dict):
            raise SchemaError("provider response must be an object")
        return payload

    def _public_get(
        self,
        endpoint: str,
        cache_path: Path,
        max_age_hours: int,
        *,
        no_cache: bool,
    ) -> dict[str, Any]:
        self._pace()
        try:
            with call_deadline(self.call_timeout_seconds):
                response = self.reader.get(
                    API_ROOT + endpoint,
                    filepath=cache_path,
                    max_age=timedelta(hours=max_age_hours),
                    no_cache=no_cache,
                )
            self.provider_calls += 1
            return self._parse_response(response)
        finally:
            self._last_call_at = time.monotonic()

    def fetch_json(
        self, endpoint: str, cache_key: str, max_age_hours: int
    ) -> tuple[dict[str, Any], str]:
        cached_mapping = self._mapping_cache.get(cache_key)
        if cached_mapping and cached_mapping[0] > self.now():
            return cached_mapping[1], "hit"
        cache_path = self.cache_dir / f"{cache_key}.json"
        cache_path.parent.mkdir(parents=True, exist_ok=True)
        was_cached = cache_path.exists()
        try:
            payload = self._public_get(endpoint, cache_path, max_age_hours, no_cache=False)
        except SchemaError:
            self._quarantine(cache_path)
            try:
                payload = self._public_get(endpoint, cache_path, max_age_hours, no_cache=True)
            except SchemaError:
                self._quarantine(cache_path)
                if cache_key in self._last_good:
                    return self._last_good[cache_key], "stale"
                raise
        self._last_good[cache_key] = payload
        if cache_key.startswith(
            ("seasons-", "tournament-", "transfer-history-", "team-", "statistics-seasons-")
        ):
            self._mapping_cache[cache_key] = (
                self.now() + timedelta(hours=max_age_hours),
                payload,
            )
        return payload, "hit" if was_cached else "miss"

    @staticmethod
    def _quarantine(cache_path: Path) -> None:
        if not cache_path.exists():
            return
        digest = hashlib.sha256(cache_path.read_bytes()).hexdigest()[:12]
        quarantine = cache_path.with_name(f"{cache_path.name}.corrupt-{digest}")
        os.replace(cache_path, quarantine)

    def _invalidate_cache(self, cache_key: str) -> None:
        self._mapping_cache.pop(cache_key, None)
        self._last_good.pop(cache_key, None)
        (self.cache_dir / f"{cache_key}.json").unlink(missing_ok=True)

    def _profile(self, player_id: str) -> tuple[dict[str, Any], str]:
        payload, cache_status = self.fetch_json(
            f"player/{player_id}",
            f"profile-{player_id}",
            self.profile_max_age_hours,
        )
        player = payload.get("player")
        if not isinstance(player, dict) or str(player.get("id", "")) != player_id:
            raise SchemaError("invalid player profile envelope")
        return payload, cache_status

    def _as_of_date(self, item: dict[str, Any]) -> tuple[datetime, bool]:
        value = item.get("as_of_date")
        explicit = isinstance(value, str) and bool(value.strip())
        if not explicit:
            current = self.now()
            if current.tzinfo is None:
                current = current.replace(tzinfo=timezone.utc)
            return current.astimezone(timezone.utc), False
        try:
            normalized = optional_as_of_date(value, "as_of_date")
            parsed = datetime.fromisoformat(normalized.replace("Z", "+00:00"))
        except (TypeError, ValueError):
            current = self.now()
            if current.tzinfo is None:
                current = current.replace(tzinfo=timezone.utc)
            return current.astimezone(timezone.utc), False
        return parsed.astimezone(timezone.utc), True

    @staticmethod
    def _is_not_found(error: BaseException) -> bool:
        for candidate in (
            getattr(error, "status_code", None),
            getattr(error, "status", None),
            getattr(getattr(error, "response", None), "status_code", None),
        ):
            if candidate == 404:
                return True
        return bool(re.search(r"\b404\b|not[ -]?found", str(error), re.IGNORECASE))

    @staticmethod
    def _history_timestamp(entry: dict[str, Any]) -> datetime | None:
        value = entry.get("transferDateTimestamp")
        if isinstance(value, str) and value.strip().isdigit():
            value = int(value.strip())
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            try:
                return datetime.fromtimestamp(value, timezone.utc)
            except (OverflowError, OSError, ValueError):
                return None
        value = entry.get("transferDate")
        if not isinstance(value, str) or not value.strip():
            return None
        try:
            parsed = datetime.fromisoformat(value.strip().replace("Z", "+00:00"))
        except ValueError:
            return None
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=timezone.utc)
        return parsed.astimezone(timezone.utc)

    @staticmethod
    def _history_entries(
        payload: dict[str, Any], as_of: datetime, *, allow_undated: bool
    ) -> list[dict[str, Any]]:
        history = payload.get("transferHistory")
        if not isinstance(history, list):
            raise SchemaError("invalid transfer history envelope")
        entries: list[dict[str, Any]] = []
        for entry in history:
            if not isinstance(entry, dict):
                continue
            transfer_from = entry.get("transferFrom")
            transfer_to = entry.get("transferTo")
            if not isinstance(transfer_from, dict):
                transfer_from = (
                    {"name": entry.get("fromTeamName")}
                    if isinstance(entry.get("fromTeamName"), str)
                    else None
                )
            if not isinstance(transfer_to, dict):
                transfer_to = (
                    {"name": entry.get("toTeamName")}
                    if isinstance(entry.get("toTeamName"), str)
                    else None
                )
            if not isinstance(transfer_from, dict) or not isinstance(transfer_to, dict):
                continue
            if not any(
                isinstance(team.get(field), (str, int)) and str(team.get(field)).strip()
                for team in (transfer_from, transfer_to)
                for field in ("id", "name")
            ):
                continue
            timestamp = SofascoreAdapter._history_timestamp(entry)
            if timestamp is None and not allow_undated:
                continue
            if timestamp is not None and timestamp > as_of:
                continue
            normalized_entry = dict(entry)
            normalized_entry["transferFrom"] = transfer_from
            normalized_entry["transferTo"] = transfer_to
            entries.append({"entry": normalized_entry, "timestamp": timestamp})
        entries.sort(
            key=lambda value: value["timestamp"] or datetime.min.replace(tzinfo=timezone.utc),
            reverse=True,
        )
        return entries

    @staticmethod
    def _team_matches(team: dict[str, Any], names: list[str]) -> bool:
        return any(_reported_club_matches(name, team) for name in names)

    def _source_transfer(
        self, entries: list[dict[str, Any]], source_names: list[str]
    ) -> dict[str, Any] | None:
        for candidate in entries:
            entry = candidate["entry"]
            transfer_to = entry["transferTo"]
            transfer_from = entry["transferFrom"]
            if self._team_matches(transfer_to, source_names):
                return {
                    "team": transfer_to,
                    "entry": entry,
                    "preceding_team": transfer_from,
                }
            if self._team_matches(transfer_from, source_names):
                return {"team": transfer_from, "entry": entry, "preceding_team": None}
        return None

    def _preceding_transfer_team(
        self,
        entries: list[dict[str, Any]],
        source_team: dict[str, Any],
        source_names: list[str],
    ) -> dict[str, Any] | None:
        names = [
            *source_names,
            source_team.get("name") if isinstance(source_team.get("name"), str) else None,
        ]
        names = [name for name in names if isinstance(name, str)]
        for candidate in entries:
            entry = candidate["entry"]
            if self._team_matches(entry["transferTo"], names):
                return entry["transferFrom"]
        return None

    def _team_detail(self, team: dict[str, Any]) -> dict[str, Any] | None:
        tournament = team.get("primaryUniqueTournament")
        if isinstance(tournament, dict) and str(tournament.get("id", "")).isdecimal():
            return team
        team_id = str(team.get("id", ""))
        if not team_id.isdecimal():
            return None
        payload, _ = self.fetch_json(
            f"team/{team_id}", f"team-{team_id}", self.mapping_max_age_hours
        )
        detail = payload.get("team")
        if not isinstance(detail, dict) or str(detail.get("id", "")) != team_id:
            raise SchemaError("invalid team envelope")
        return detail

    def _competition_for_team(self, team: dict[str, Any]) -> dict[str, str] | None:
        tournament = team.get("primaryUniqueTournament")
        tournament_id = str(tournament.get("id", "")) if isinstance(tournament, dict) else ""
        if not tournament_id.isdecimal():
            return None
        metadata_payload, _ = self.fetch_json(
            f"unique-tournament/{tournament_id}",
            f"tournament-{tournament_id}",
            self.mapping_max_age_hours,
        )
        candidate_team = dict(team)
        candidate_tournament = dict(tournament)
        metadata = metadata_payload.get("uniqueTournament")
        candidate_category = candidate_tournament.get("category")
        if (
            isinstance(metadata, dict)
            and isinstance(metadata.get("category"), dict)
            and (
                not isinstance(candidate_category, dict)
                or not candidate_category.get("alpha2")
            )
        ):
            candidate_tournament["category"] = metadata["category"]
        candidate_team["primaryUniqueTournament"] = candidate_tournament
        return validated_competition({"team": candidate_team}, metadata_payload)

    def _season_for_competition(
        self,
        competition: dict[str, str],
        metadata_payload: dict[str, Any],
        as_of: datetime,
        *,
        season_mapping: dict[str, Any] | None,
        historical: bool,
    ) -> dict[str, str] | None:
        if (
            season_mapping
            and not historical
            and season_mapping.get("state") == "latest_completed"
        ):
            return dict(season_mapping)
        tournament_id = competition["provider_unique_tournament_id"]
        seasons_payload, _ = self.fetch_json(
            f"unique-tournament/{tournament_id}/seasons",
            f"seasons-{tournament_id}",
            self.mapping_max_age_hours,
        )
        return select_reporting_season(seasons_payload, metadata_payload, now=as_of)

    def _statistics_request(
        self,
        player_id: str,
        competition: dict[str, str],
        season: dict[str, str],
    ) -> dict[str, Any]:
        tournament_id = competition["provider_unique_tournament_id"]
        season_id = season["provider_season_id"]
        try:
            payload, cache_status = self.fetch_json(
                f"player/{player_id}/unique-tournament/{tournament_id}/season/{season_id}/statistics/overall",
                f"statistics-{player_id}-{tournament_id}-{season_id}",
                self.stats_max_age_hours,
            )
        except Exception as error:
            if isinstance(error, SchemaError):
                raise
            return {
                "status": "missing" if self._is_not_found(error) else "unavailable",
                "error": error,
            }
        payload_error = payload.get("error")
        if (
            str(payload.get("status", "")) == "404"
            or str(payload.get("code", "")) == "404"
            or isinstance(payload_error, dict)
            and str(payload_error.get("code", "")) == "404"
        ):
            return {"status": "missing"}
        return {
            "status": "fresh",
            "statistics": self._normalize_statistics(payload, competition, season),
            "payload": payload,
            "cache_status": cache_status,
        }

    def _team_statistics(
        self,
        player_id: str,
        team: dict[str, Any],
        as_of: datetime,
        *,
        season_mapping: dict[str, Any] | None,
        historical: bool,
    ) -> dict[str, Any]:
        hydrated = self._team_detail(team)
        if hydrated is None:
            return {"status": "unavailable"}
        competition = self._competition_for_team(hydrated)
        if competition is None:
            return {"status": "unavailable", "team": hydrated}
        tournament_id = competition["provider_unique_tournament_id"]
        metadata_payload, _ = self.fetch_json(
            f"unique-tournament/{tournament_id}",
            f"tournament-{tournament_id}",
            self.mapping_max_age_hours,
        )
        season = self._season_for_competition(
            competition,
            metadata_payload,
            as_of,
            season_mapping=season_mapping,
            historical=historical,
        )
        if season is None:
            return {"status": "unavailable", "team": hydrated}
        result = self._statistics_request(player_id, competition, season)
        result.update({"team": hydrated, "competition": competition, "season": season})
        return result

    def _catalogue_candidates(
        self, player_id: str, as_of: datetime
    ) -> list[dict[str, Any]]:
        payload, _ = self.fetch_json(
            f"player/{player_id}/statistics/seasons",
            f"statistics-seasons-{player_id}",
            self.mapping_max_age_hours,
        )
        groups = payload.get("uniqueTournamentSeasons")
        if not isinstance(groups, list):
            return []
        candidates: dict[str, dict[str, Any]] = {}
        for group in groups:
            if not isinstance(group, dict):
                continue
            tournament = group.get("uniqueTournament")
            seasons = group.get("seasons")
            if not isinstance(tournament, dict) or not isinstance(seasons, list):
                continue
            tournament_id = str(tournament.get("id", ""))
            if not tournament_id.isdecimal() or tournament_id in candidates:
                continue
            metadata_payload, _ = self.fetch_json(
                f"unique-tournament/{tournament_id}",
                f"tournament-{tournament_id}",
                self.mapping_max_age_hours,
            )
            metadata = metadata_payload.get("uniqueTournament")
            category = metadata.get("category") if isinstance(metadata, dict) else None
            alpha2 = category.get("alpha2") if isinstance(category, dict) else None
            if (
                not isinstance(alpha2, str)
                or not re.fullmatch(r"[A-Z]{2}", alpha2)
                or metadata.get("tier") != 1
            ):
                continue
            tournament_for_team = dict(tournament)
            if (
                isinstance(metadata, dict)
                and isinstance(metadata.get("category"), dict)
                and (
                    not isinstance(tournament_for_team.get("category"), dict)
                    or not tournament_for_team["category"].get("alpha2")
                )
            ):
                tournament_for_team["category"] = metadata.get("category")
            team = {
                "id": 0,
                "name": "Catalogue candidate",
                "national": False,
                "gender": "M",
                "sport": {"slug": "football"},
                "primaryUniqueTournament": tournament_for_team,
            }
            competition = validated_competition({"team": team}, metadata_payload)
            if competition is None:
                continue
            candidate = {
                "competition": competition,
                "metadata": metadata_payload,
                "seasons": {"seasons": seasons},
            }
            candidates[tournament_id] = candidate
        return list(candidates.values())

    def _catalogue_statistics(
        self,
        player_id: str,
        as_of: datetime,
        *,
        excluded: set[tuple[str, str]] | None = None,
    ) -> dict[str, Any]:
        candidates = self._catalogue_candidates(player_id, as_of)
        if len(candidates) != 1:
            return {"status": "not_found"}
        candidate = candidates[0]
        season = select_reporting_season(
            candidate["seasons"], candidate["metadata"], now=as_of
        )
        if season is None:
            return {"status": "not_found"}
        statistics_key = (
            candidate["competition"]["provider_unique_tournament_id"],
            season["provider_season_id"],
        )
        if statistics_key in (excluded or set()):
            return {"status": "not_found"}
        result = self._statistics_request(player_id, candidate["competition"], season)
        result.update({"competition": candidate["competition"], "season": season})
        return result

    @staticmethod
    def _selection_provenance(
        team: dict[str, Any] | None, basis: str
    ) -> dict[str, Any]:
        chosen_team = None
        if isinstance(team, dict) and str(team.get("id", "")).isdecimal():
            name = team.get("name")
            if isinstance(name, str) and name.strip():
                chosen_team = {
                    "provider_team_id": str(team["id"]),
                    "name": name.strip(),
                }
        return {
            "selector_version": STATISTICS_SELECTOR_VERSION,
            "chosen_team": chosen_team,
            "basis": basis,
        }

    def _normalize_profile(self, payload: dict[str, Any]) -> dict[str, Any]:
        player = payload["player"]
        canonical_name = player.get("name")
        canonical_name = (
            " ".join(canonical_name.split()) if isinstance(canonical_name, str) else None
        )
        canonical_name = canonical_name or None
        team = player.get("team") if isinstance(player.get("team"), dict) else None
        country = player.get("country") if isinstance(player.get("country"), dict) else {}
        market = (
            player.get("proposedMarketValueRaw")
            if isinstance(player.get("proposedMarketValueRaw"), dict)
            else {}
        )
        date_of_birth = None
        age = None
        timestamp = nullable_int(player.get("dateOfBirthTimestamp"))
        if timestamp is not None:
            try:
                born = datetime.fromtimestamp(timestamp, timezone.utc).date()
            except (OSError, OverflowError, ValueError):
                born = None
            today = self.now().date()
            if born is not None and born <= today:
                date_of_birth = born.isoformat()
                age = today.year - born.year - ((today.month, today.day) < (born.month, born.day))
        height = nonnegative_int(player.get("height"))
        preferred_foot = player.get("preferredFoot")
        if isinstance(preferred_foot, str) and preferred_foot.casefold() in {"left", "right"}:
            preferred_foot = preferred_foot.title()
        else:
            preferred_foot = None
        market_value = nonnegative_int(market.get("value"))
        market_currency = market.get("currency")
        if not (
            isinstance(market_currency, str)
            and len(market_currency) == 3
            and market_currency.isascii()
            and market_currency.isalpha()
            and market_currency.isupper()
        ):
            market_currency = None
        if market_currency is None:
            market_value = None
        return {
            "canonical_name": canonical_name,
            "current_club": {
                "provider_team_id": str(team["id"]),
                "name": team.get("name") if isinstance(team.get("name"), str) else None,
            }
            if team and isinstance(team.get("id"), int)
            else None,
            "nationality": country.get("name") if isinstance(country.get("name"), str) else None,
            "age": age,
            "date_of_birth": date_of_birth,
            "primary_position": POSITION_NAMES.get(player.get("position")),
            "height_cm": height if height is not None and 100 <= height <= 250 else None,
            "preferred_foot": preferred_foot,
            "market_value": market_value,
            "market_value_currency": market_currency,
            "retrieved_at": self.now().isoformat().replace("+00:00", "Z"),
        }

    def _normalize_statistics(
        self,
        payload: dict[str, Any],
        competition: dict[str, str],
        season: dict[str, str],
    ) -> dict[str, Any]:
        statistics = payload.get("statistics")
        if not isinstance(statistics, dict):
            raise SchemaError("invalid statistics envelope")
        appearances = nonnegative_int(statistics.get("appearances"))
        starts = nonnegative_int(statistics.get("matchesStarted"))
        if starts is not None and appearances is not None and starts > appearances:
            starts = None
        minutes = nonnegative_int(statistics.get("minutesPlayed"))
        rating = nonnegative_float(statistics.get("rating"))
        if rating is not None and rating > 10:
            rating = None
        return {
            "competition": competition.get("name") or None,
            "provider_unique_tournament_id": competition["provider_unique_tournament_id"],
            "season": season.get("label") or None,
            "provider_season_id": season["provider_season_id"],
            "season_state": season.get("state") or None,
            "scope": "selected_domestic_league_all_clubs",
            "appearances": appearances,
            "starts": starts,
            "minutes_played": minutes,
            "minutes_per_game": round(minutes / appearances, 1)
            if minutes is not None and appearances
            else None,
            "goals": nonnegative_int(statistics.get("goals")),
            "expected_goals": nonnegative_float(statistics.get("expectedGoals")),
            "assists": nonnegative_int(statistics.get("assists")),
            "expected_assists": nonnegative_float(statistics.get("expectedAssists")),
            "average_rating": rating,
            "clean_sheets": nonnegative_int(statistics.get("cleanSheet")),
            "saves": nonnegative_int(statistics.get("saves")),
            "retrieved_at": self.now().isoformat().replace("+00:00", "Z"),
        }

    def enrich(self, item: dict[str, Any]) -> dict[str, Any]:
        result = self._enrich(item)
        result["resolver_version"] = RESOLVER_VERSION
        return result

    def _enrich(self, item: dict[str, Any]) -> dict[str, Any]:
        calls_before = self.provider_calls
        item_key = item["item_key"]
        override = manual_identity_decision(
            item.get("identity_overrides") or [], now=self.now()
        )
        rejected_player_ids: set[str] = set()
        if override and override["action"] in {"reject_all", "conflict"}:
            return {
                "item_key": item_key,
                "status": "unresolved",
                "provider_calls": 0,
                "identity": None,
                "profile": None,
                "statistics": None,
                "candidates": [],
                "error": {
                    "code": "manual_identity_rejected"
                    if override["action"] == "reject_all"
                    else "manual_identity_conflict",
                    "retryable": False,
                },
            }
        if override and override["action"] == "resolve":
            player_id = override["provider_player_id"]
            identity = known_identity(player_id)
            identity.update(score=100, margin=100, resolver_version="manual-identity-v1")
            manual_resolved = True
        else:
            player_id = item.get("known_provider_player_id")
            manual_resolved = False
            if override and override["action"] == "reject":
                rejected_player_ids = override["provider_player_ids"]
                if player_id in rejected_player_ids:
                    player_id = None
        if player_id:
            if not manual_resolved:
                identity = known_identity(player_id)
        else:
            current_club_names = [
                club_name
                for club_name in [
                    item.get("current_club_name"),
                    *(item.get("current_club_aliases") or []),
                ]
                if isinstance(club_name, str) and is_discriminating_club_name(club_name)
            ]
            destination_club_names = [
                club_name
                for club_name in [
                    item.get("destination_club_name"),
                    *(item.get("destination_club_aliases") or []),
                ]
                if isinstance(club_name, str) and is_discriminating_club_name(club_name)
            ]
            completed_move = (
                item.get("classification") in {"official_confirmed", "loan"}
                or item.get("move_type") == "loan"
            )
            destination_weight = (
                30
                if completed_move or not current_club_names
                else 20
            )
            search, _ = self.fetch_json(
                f"search/all?q={quote(item['reported_name'], safe='')}",
                f"search-{hashlib.sha256(item['reported_name'].encode()).hexdigest()}",
                self.profile_max_age_hours,
            )
            search_payloads = [search]
            resolve_options = {
                "aliases": item.get("aliases"),
                "provider_team_id": (item.get("team_mapping") or {}).get("provider_team_id"),
                "reported_club_names": current_club_names,
                "destination_club_names": destination_club_names,
                "destination_weight": destination_weight,
                "allow_surname_only_match": item.get("allow_surname_only_match", False),
                "allow_exact_name_without_club": item.get("allow_exact_name_without_club", False),
                "rejected_player_ids": rejected_player_ids,
            }
            resolution = resolve_search(item["reported_name"], search, **resolve_options)
            if resolution["status"] != "resolved" and item.get("aliases"):
                alias = item["aliases"][0]
                alias_search, _ = self.fetch_json(
                    f"search/all?q={quote(alias, safe='')}",
                    f"search-{hashlib.sha256(alias.encode()).hexdigest()}",
                    self.profile_max_age_hours,
                )
                search_payloads.append(alias_search)
                resolution = resolve_search(
                    item["reported_name"], alias_search, **resolve_options
                )
            former_names = [
                club_name
                for club_name in [
                    item.get("former_club_name"),
                    *(item.get("former_club_aliases") or []),
                ]
                if isinstance(club_name, str) and is_discriminating_club_name(club_name)
            ]
            fallback_club_names = [
                *current_club_names,
                *destination_club_names,
                *former_names,
            ]
            if resolution["status"] != "resolved" and fallback_club_names:
                candidates_by_id = {}
                for search_payload in search_payloads:
                    for candidate in exact_name_candidates(
                        item["reported_name"],
                        search_payload,
                        aliases=item.get("aliases"),
                        rejected_player_ids=rejected_player_ids,
                    ):
                        candidates_by_id[candidate["provider_player_id"]] = candidate
                exact_candidates = sorted(
                    candidates_by_id.values(),
                    key=lambda candidate: int(candidate["provider_player_id"]),
                )
                if len(exact_candidates) > 3:
                    resolution = {"status": "ambiguous", "candidates": exact_candidates[:5]}
                else:
                    history_matches = []
                    for candidate in exact_candidates:
                        candidate_id = candidate["provider_player_id"]
                        history, _ = self.fetch_json(
                            f"player/{candidate_id}/transfer-history",
                            f"transfer-history-{candidate_id}",
                            24,
                        )
                        try:
                            matched = transfer_history_matches_club(
                                history, fallback_club_names
                            )
                        except ValueError as error:
                            self._invalidate_cache(f"transfer-history-{candidate_id}")
                            raise SchemaError(str(error)) from error
                        if matched:
                            history_matches.append(candidate)
                    if len(history_matches) == 1:
                        candidate = history_matches[0]
                        identity = known_identity(candidate["provider_player_id"])
                        identity.update(score=80, margin=80)
                        resolution = {
                            "status": "resolved",
                            "identity": identity,
                            "candidates": exact_candidates[:5],
                        }
                    elif len(history_matches) > 1:
                        tied = [{**candidate, "score": 80} for candidate in history_matches]
                        resolution = {"status": "ambiguous", "candidates": tied[:5]}
                    else:
                        resolution = {"status": "unresolved", "candidates": exact_candidates[:5]}
            if resolution["status"] != "resolved":
                status = resolution["status"]
                return {
                    "item_key": item_key,
                    "status": status,
                    "provider_calls": self.provider_calls - calls_before,
                    "identity": None,
                    "profile": None,
                    "statistics": None,
                    "candidates": resolution["candidates"],
                    "error": {
                        "code": "identity_margin_too_small"
                        if status == "ambiguous"
                        else "identity_unresolved",
                        "retryable": False,
                    },
                }
            identity = resolution["identity"]
            player_id = identity["provider_player_id"]

        profile_payload, profile_cache = self._profile(player_id)
        profile = self._normalize_profile(profile_payload)
        raw_player = profile_payload["player"]
        team = raw_player.get("team") if isinstance(raw_player.get("team"), dict) else None
        if team is None:
            return self._partial(
                item_key, identity, profile, calls_before, "unattached", profile_payload
            )

        as_of, historical = self._as_of_date(item)
        source_names = [
            club_name
            for club_name in [
                item.get("current_club_name"),
                *(item.get("current_club_aliases") or []),
            ]
            if isinstance(club_name, str) and is_discriminating_club_name(club_name)
        ]

        def fresh_result(statistics_result: dict[str, Any], selection: dict[str, Any]):
            return {
                "item_key": item_key,
                "status": "fresh",
                "provider_calls": self.provider_calls - calls_before,
                "identity": identity,
                "profile": profile,
                "statistics": statistics_result["statistics"],
                "provenance": {
                    "adapter_schema": ADAPTER_SCHEMA,
                    "profile_cache": profile_cache,
                    "statistics_cache": statistics_result["cache_status"],
                    "statistics_selection": selection,
                    "raw_payloads": {
                        "profile": profile_payload,
                        "statistics": statistics_result["payload"],
                    },
                },
                "warnings": [],
            }

        if historical and not source_names:
            catalogue_result = self._catalogue_statistics(player_id, as_of)
            if catalogue_result["status"] == "fresh":
                return fresh_result(
                    catalogue_result,
                    self._selection_provenance(None, "single_catalogue_domestic_candidate"),
                )
            if catalogue_result["status"] == "unavailable":
                return self._partial(
                    item_key,
                    identity,
                    profile,
                    calls_before,
                    "statistics_unavailable",
                    profile_payload,
                )
            return self._partial(
                item_key,
                identity,
                profile,
                calls_before,
                "statistics_not_found",
                profile_payload,
            )

        if historical and source_names:
            attempted_statistics: set[tuple[str, str]] = set()
            source_team = team if self._team_matches(team, source_names) else None
            source_transfer = None
            history_entries: list[dict[str, Any]] = []
            history_loaded = False
            if source_team is None:
                history_payload, _ = self.fetch_json(
                    f"player/{player_id}/transfer-history",
                    f"transfer-history-{player_id}",
                    self.mapping_max_age_hours,
                )
                history_entries = self._history_entries(
                    history_payload, as_of, allow_undated=False
                )
                history_loaded = True
                source_transfer = self._source_transfer(history_entries, source_names)
                source_team = source_transfer["team"] if source_transfer else None

            if source_team is not None:
                source_result = self._team_statistics(
                    player_id,
                    source_team,
                    as_of,
                    season_mapping=None,
                    historical=True,
                )
                if source_result.get("competition") and source_result.get("season"):
                    attempted_statistics.add(
                        (
                            source_result["competition"]["provider_unique_tournament_id"],
                            source_result["season"]["provider_season_id"],
                        )
                    )
                source_selection = self._selection_provenance(
                    source_result.get("team") or source_team,
                    "reported_source_club",
                )
                if source_result["status"] == "fresh":
                    return fresh_result(source_result, source_selection)
                if source_result["status"] == "unavailable" and source_result.get("error"):
                    return self._partial(
                        item_key,
                        identity,
                        profile,
                        calls_before,
                        "statistics_unavailable",
                        profile_payload,
                        source_selection,
                    )

                if not history_loaded:
                    history_payload, _ = self.fetch_json(
                        f"player/{player_id}/transfer-history",
                        f"transfer-history-{player_id}",
                        self.mapping_max_age_hours,
                    )
                    history_entries = self._history_entries(
                        history_payload, as_of, allow_undated=False
                    )
                    history_loaded = True
                    source_transfer = self._source_transfer(history_entries, source_names)
                preceding_team = self._preceding_transfer_team(
                    history_entries,
                    source_result.get("team") or source_team,
                    source_names,
                )
                if preceding_team:
                    preceding_result = self._team_statistics(
                        player_id,
                        preceding_team,
                        as_of,
                        season_mapping=None,
                        historical=True,
                    )
                    if preceding_result.get("competition") and preceding_result.get("season"):
                        attempted_statistics.add(
                            (
                                preceding_result["competition"]["provider_unique_tournament_id"],
                                preceding_result["season"]["provider_season_id"],
                            )
                        )
                    preceding_selection = self._selection_provenance(
                        preceding_result.get("team") or preceding_team,
                        "preceding_transfer_club",
                    )
                    if preceding_result["status"] == "fresh":
                        return fresh_result(preceding_result, preceding_selection)
                    if preceding_result["status"] == "unavailable" and preceding_result.get("error"):
                        return self._partial(
                            item_key,
                            identity,
                            profile,
                            calls_before,
                            "statistics_unavailable",
                            profile_payload,
                            preceding_selection,
                        )

            catalogue_result = self._catalogue_statistics(
                player_id, as_of, excluded=attempted_statistics
            )
            if catalogue_result["status"] == "fresh":
                return fresh_result(
                    catalogue_result,
                    self._selection_provenance(None, "single_catalogue_domestic_candidate"),
                )
            if catalogue_result["status"] == "unavailable":
                return self._partial(
                    item_key,
                    identity,
                    profile,
                    calls_before,
                    "statistics_unavailable",
                    profile_payload,
                )
            return self._partial(
                item_key,
                identity,
                profile,
                calls_before,
                "statistics_not_found",
                profile_payload,
            )

        team_mapping = item.get("team_mapping")
        season_mapping = item.get("season_mapping")
        completed_move = (
            item.get("completed_move") is True
            or item.get("classification") in {"official_confirmed", "loan"}
            or item.get("move_type") == "loan"
        )
        destination_club_names = [
            club_name
            for club_name in [
                item.get("destination_club_name"),
                *(item.get("destination_club_aliases") or []),
            ]
            if isinstance(club_name, str) and is_discriminating_club_name(club_name)
        ]
        if team_mapping and str(team.get("id", "")) != team_mapping["provider_team_id"]:
            if not completed_move or not any(
                _reported_club_matches(club_name, team)
                for club_name in destination_club_names
            ):
                return self._partial(
                    item_key, identity, profile, calls_before, "club_conflict", profile_payload
                )
            team_mapping = None

        tournament = team.get("primaryUniqueTournament") or {}
        if team_mapping and str(tournament.get("id", "")) != team_mapping["provider_unique_tournament_id"]:
            if not completed_move:
                return self._partial(
                    item_key,
                    identity,
                    profile,
                    calls_before,
                    "unsupported_competition",
                    profile_payload,
                )
            team_mapping = None
            season_mapping = None

        metadata_payload = None
        if team_mapping:
            competition = {
                "provider_unique_tournament_id": team_mapping[
                    "provider_unique_tournament_id"
                ],
                "name": tournament.get("name") or "",
            }
        else:
            tournament_id = str(tournament.get("id", ""))
            metadata_payload, _ = self.fetch_json(
                f"unique-tournament/{tournament_id}",
                f"tournament-{tournament_id}",
                self.mapping_max_age_hours,
            )
            competition = validated_competition(raw_player, metadata_payload)
            if competition is None:
                return self._partial(
                    item_key,
                    identity,
                    profile,
                    calls_before,
                    "unsupported_competition",
                    profile_payload,
                )

        season = season_mapping if not historical else None
        if season and season.get("state") == "latest_completed":
            season = dict(season)
        else:
            tournament_id = competition["provider_unique_tournament_id"]
            seasons_payload, _ = self.fetch_json(
                f"unique-tournament/{tournament_id}/seasons",
                f"seasons-{tournament_id}",
                self.mapping_max_age_hours,
            )
            if metadata_payload is None:
                metadata_payload, _ = self.fetch_json(
                    f"unique-tournament/{tournament_id}",
                    f"tournament-{tournament_id}",
                    self.mapping_max_age_hours,
                )
            season = select_reporting_season(seasons_payload, metadata_payload, now=as_of)
            if season is None:
                return self._partial(
                    item_key,
                    identity,
                    profile,
                    calls_before,
                    "missing_season",
                    profile_payload,
                )

        statistics_result = self._statistics_request(player_id, competition, season)
        if statistics_result["status"] == "unavailable":
            return self._partial(
                item_key,
                identity,
                profile,
                calls_before,
                "statistics_unavailable",
                profile_payload,
            )
        if statistics_result["status"] == "missing":
            return self._partial(
                item_key,
                identity,
                profile,
                calls_before,
                "statistics_not_found",
                profile_payload,
            )
        return fresh_result(
            statistics_result,
            self._selection_provenance(team, "profile_current_club"),
        )

    def _partial(
        self,
        item_key: str,
        identity: dict[str, Any],
        profile: dict[str, Any],
        calls_before: int,
        code: str,
        profile_payload: dict[str, Any],
        selection: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        return {
            "item_key": item_key,
            "status": "partial"
            if code in {"unattached", "missing_season", "statistics_unavailable", "statistics_not_found"}
            else code,
            "provider_calls": self.provider_calls - calls_before,
            "identity": identity,
            "profile": profile,
            "statistics": None,
            "provenance": {
                "adapter_schema": ADAPTER_SCHEMA,
                **({"statistics_selection": selection} if selection else {}),
                "raw_payloads": {"profile": profile_payload},
            },
            "warnings": [{
                "code": code,
                "retryable": code in {"missing_season", "statistics_unavailable"},
            }],
        }
