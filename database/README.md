# PostgreSQL persistence

This directory contains the PostgreSQL 16 persistence layer for the football-transfer monitor.

## Data model

- `source_accounts` and `raw_posts` store the configured X sources and their original posts. X account and post IDs are `text`, never numeric types.
- `transfer_reports` holds one merged report per deterministic `dedupe_key`. `transfer_report_sources` retains every supporting raw post and permits at most one preferred source.
- `transfer_report_revisions` records each digestable version. A revision can appear in only one `digest_items` row, so a retry cannot resend it.
- `players` stores the normalized player identity used to link and deduplicate news reports.
- `workflow_runs`, `failures`, and `retry_states` record execution, failure, and retry state without duplicating retries.
- `player_provider_ids`, `player_aliases`, `player_identity_overrides`, and `transfer_report_player_resolutions` preserve canonical players while recording verified Sofascore identity decisions per exact report context.
- `provider_teams`, `team_aliases`, `provider_competitions`, `provider_seasons`, and `team_competition_mappings` store structural club, domestic-league, and selected-season mappings without guessing unavailable values.
- `player_profile_snapshots` and `player_season_stat_snapshots` retain immutable normalized provider results. `player_enrichment_attempts` records restart-safe per-report outcomes, including ambiguity and fail-open errors.
- `current_player_enrichment` exposes the latest profile and currently selected-season statistics for resolved reports. It does not hide stale rows.

`dedupe_key` values are application-generated stable identifiers. The workflow must use the same value when replaying a post.

## Initialize and migrate

Run these commands from `deploy/support/` after confirming its ignored local `.env` contains `POSTGRES_USER` and `POSTGRES_PASSWORD`:

```bash
docker network create transfers_net
docker compose up -d transfers-postgres
docker compose --profile maintenance run --rm transfers-db-migrate
```

The first database start runs `migrate.sql` automatically. The maintenance command is safe to repeat: it holds a PostgreSQL advisory lock and records each applied migration in `app_schema_migrations`.

## Run SQL tests

```bash
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql'
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql'
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/003_soccerdata_enrichment.sql'
```

All tests start a transaction and roll it back. They leave no fixture data behind. The second test covers repeated conflict-safe source/report writes, material revision uniqueness, retry-state increment, workflow replay attempts, and `sending` to `unknown` recovery. The third checks the minimum enrichment migration, provider/report/snapshot/attempt uniqueness, canonical-player preservation, the current view, and frozen Discord request payloads.

## Digest safety

Reserve a digest delivery and its items in one database transaction before sending the Discord request. Mark it `sending` before the HTTP request, then `sent` only after Discord returns its message ID.

If the worker stops after sending but before recording the response, mark that delivery `unknown` during recovery. Do not automatically retry `sending` or `unknown` deliveries: PostgreSQL cannot determine whether Discord accepted an interrupted request. This conservative rule prevents duplicate Discord digests.

The first delivery reservation writes `digest_deliveries.request_payload`. Conflict handling may update delivery state, but must return and send the stored payload without replacing it.

## Manual enrichment overrides

Manual rows are audited production decisions. First inspect the existing provider rows and `player_enrichment_attempts.evidence`; use only exact provider IDs and normalized keys already supported by evidence. Never guess a player, team, competition, season, date, or missing statistic.

Open an audited PostgreSQL session:

```bash
docker compose -f deploy/support/compose.yaml exec transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1'
```

Replace every `<...>` value below before running one transaction at a time. Record a real operator name, reason, evidence reference, and reviewed expiry.

### Player identity

An active `resolve` override has highest resolution precedence for its exact reported-name/current-club/destination context. Revoke the prior terminal override instead of deleting it, then insert the reviewed decision:

```sql
BEGIN;

UPDATE player_identity_overrides
SET revoked_at = CURRENT_TIMESTAMP
WHERE provider = 'sofascore'
  AND reported_name_key = '<exact-reported-name-key>'
  AND current_club_key IS NOT DISTINCT FROM '<exact-current-club-key>'
  AND destination_club_key IS NOT DISTINCT FROM '<exact-destination-club-key>'
  AND revoked_at IS NULL
  AND override_action IN ('resolve', 'reject_all');

INSERT INTO player_identity_overrides (
  reported_name_key, current_club_key, destination_club_key,
  override_action, provider_player_id, effective_at,
  reason, operator_name, evidence
) VALUES (
  '<exact-reported-name-key>',
  '<exact-current-club-key>',
  '<exact-destination-club-key>',
  'resolve',
  '<verified-decimal-provider-player-id>',
  CURRENT_TIMESTAMP,
  '<reason>',
  '<operator>',
  jsonb_build_object('reference', '<ticket-or-review-reference>')
)
RETURNING *;

COMMIT;
```

Use SQL `NULL`, without quotes, for a missing club key. To block one candidate, use `reject_candidate` with its verified provider player ID. To block every candidate for the exact context, use `reject_all` with a SQL `NULL` provider player ID.

### Team alias

Add a manual alias only to an existing verified provider team. The Unicode and folded keys must come from the same normalization output used by the workflow/service:

```sql
BEGIN;

INSERT INTO team_aliases (
  provider_team_id, alias, unicode_key, folded_key,
  country_context, competition_context, alias_source, evidence
)
SELECT
  team.id,
  '<reviewed-alias>',
  '<exact-unicode-key>',
  '<exact-folded-key>',
  '<country-context>',
  '<competition-context>',
  'manual',
  jsonb_build_object(
    'operator', '<operator>',
    'reason', '<reason>',
    'reference', '<ticket-or-review-reference>'
  )
FROM provider_teams AS team
WHERE team.provider = 'sofascore'
  AND team.provider_team_id = '<verified-decimal-provider-team-id>'
  AND NOT EXISTS (
    SELECT 1
    FROM team_aliases AS existing
    WHERE existing.provider_team_id = team.id
      AND existing.country_context IS NOT DISTINCT FROM '<country-context>'
      AND existing.competition_context IS NOT DISTINCT FROM '<competition-context>'
      AND existing.unicode_key = '<exact-unicode-key>'
  )
RETURNING *;

COMMIT;
```

Use SQL `NULL` for an unavailable context. A zero-row result means the provider team is absent or the exact alias already exists; inspect it instead of inserting a guessed team.

### Competition classification and team mapping

Classify only an existing reviewed competition. This example marks a verified senior men's top-tier domestic club league as eligible:

```sql
BEGIN;

UPDATE provider_competitions
SET competition_kind = 'domestic_league',
    team_scope = 'club',
    gender = 'men',
    age_group = 'senior',
    tier = 1,
    eligibility = 'eligible',
    classification_source = 'manual',
    manual_operator = '<operator>',
    manual_reason = '<reason>',
    evidence = evidence || jsonb_build_object(
      'reference', '<ticket-or-review-reference>'
    )
WHERE provider = 'sofascore'
  AND provider_unique_tournament_id =
    '<verified-decimal-provider-unique-tournament-id>'
RETURNING *;

COMMIT;
```

After classification, supersede the current team mapping and insert the reviewed effective-dated replacement:

```sql
BEGIN;

UPDATE team_competition_mappings
SET effective_to = CURRENT_TIMESTAMP,
    superseded_at = CURRENT_TIMESTAMP
WHERE provider_team_id = (
  SELECT id FROM provider_teams
  WHERE provider = 'sofascore'
    AND provider_team_id = '<verified-decimal-provider-team-id>'
)
  AND superseded_at IS NULL;

INSERT INTO team_competition_mappings (
  provider_team_id, provider_competition_id, mapping_source,
  rule_version, evidence, effective_from, verified_at, fresh_until,
  manual_reason, manual_operator
)
SELECT
  team.id,
  competition.id,
  'manual',
  'competition-v1',
  jsonb_build_object('reference', '<ticket-or-review-reference>'),
  CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP,
  '<reviewed-expiry-timestamptz>'::timestamptz,
  '<reason>',
  '<operator>'
FROM provider_teams AS team
CROSS JOIN provider_competitions AS competition
WHERE team.provider = 'sofascore'
  AND team.provider_team_id = '<verified-decimal-provider-team-id>'
  AND competition.provider = 'sofascore'
  AND competition.provider_unique_tournament_id =
    '<verified-decimal-provider-unique-tournament-id>'
RETURNING *;

COMMIT;
```

A zero-row insert is a hard stop: the verified team or competition row is missing. Do not create one manually from a display name.

### Season selection

Select only an existing provider season whose stored state is `active` or `latest_completed`. Deselect the previous row first so the one-selected-season constraint remains valid:

```sql
BEGIN;

UPDATE provider_seasons
SET is_selected = false,
    superseded_at = CURRENT_TIMESTAMP
WHERE provider_competition_id = (
  SELECT id FROM provider_competitions
  WHERE provider = 'sofascore'
    AND provider_unique_tournament_id =
      '<verified-decimal-provider-unique-tournament-id>'
)
  AND is_selected
  AND provider_season_id <> '<verified-decimal-provider-season-id>';

UPDATE provider_seasons
SET is_selected = true,
    selection_source = 'manual',
    selected_at = CURRENT_TIMESTAMP,
    superseded_at = NULL,
    fresh_until = '<reviewed-expiry-timestamptz>'::timestamptz,
    manual_reason = '<reason>',
    manual_operator = '<operator>'
WHERE provider_competition_id = (
  SELECT id FROM provider_competitions
  WHERE provider = 'sofascore'
    AND provider_unique_tournament_id =
      '<verified-decimal-provider-unique-tournament-id>'
)
  AND provider_season_id = '<verified-decimal-provider-season-id>'
  AND season_state IN ('active', 'latest_completed')
RETURNING *;

-- Use COMMIT only when the final update returned the one reviewed row.
COMMIT;
```

If the final update returns zero rows, run `ROLLBACK`; the requested competition/season/state is not eligible. Do not select the first or a future season.

## Enrichment retention and rollback

Run retention manually until an external scheduler is explicitly added:

```bash
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --command "SELECT * FROM app_prune_player_enrichment();"'
```

The function clears raw provider JSON after 30 days, prunes ordinary attempts after 90 days, and prunes old snapshots after 24 months while retaining required latest unresolved/ambiguous attempts and newest normalized snapshots. Provider identities, aliases, overrides, mappings, and report resolutions remain available for audit.

Freshness is evaluated from stored `fresh_until` and provider retrieval timestamps. Failure-gated stale attached-player profiles and statistics may be presented for at most 72 hours from retrieval; an explicitly unattached profile may be presented for at most 7 days. Retention never authorizes stale presentation and is not part of the six-hour digest path.

Migration 002 is additive and has no destructive down migration. Roll back the application by setting `PLAYER_ENRICHMENT_MODE=off`, restoring the previous workflows/images, and stopping the optional service. Keep the additive schema and its `app_schema_migrations` row. Disaster recovery restores the verified pre-002 logical backup into a new database or volume instead of dropping objects in place.
