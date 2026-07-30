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

## Enrichment retention and rollback

Run retention manually until an external scheduler is explicitly added:

```bash
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --command "SELECT * FROM app_prune_player_enrichment();"'
```

The function clears raw provider JSON after 30 days, prunes ordinary attempts after 90 days, and prunes old snapshots after 24 months while retaining required latest unresolved/ambiguous attempts and newest normalized snapshots. Provider identities, aliases, overrides, mappings, and report resolutions remain available for audit.

Migration 002 is additive and has no destructive down migration. Roll back the application by setting `PLAYER_ENRICHMENT_MODE=off`, restoring the previous workflows/images, and stopping the optional service. Keep the additive schema and its `app_schema_migrations` row. Disaster recovery restores the verified pre-002 logical backup into a new database or volume instead of dropping objects in place.
