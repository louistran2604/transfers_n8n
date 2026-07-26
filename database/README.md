# PostgreSQL persistence

This directory contains the PostgreSQL 16 persistence layer for the football-transfer monitor.

## Data model

- `source_accounts` and `raw_posts` store the configured X sources and their original posts. X account and post IDs are `text`, never numeric types.
- `transfer_reports` holds one merged report per deterministic `dedupe_key`. `transfer_report_sources` retains every supporting raw post and permits at most one preferred source.
- `transfer_report_revisions` records each digestable version. A revision can appear in only one `digest_items` row, so a retry cannot resend it.
- `players`, `transfermarkt_profiles`, and the three history tables store the selected Transfermarkt data. Scraper entries use stable `source_entry_key` values for idempotent upserts.
- `workflow_runs`, `failures`, and `retry_states` record execution, failure, and retry state without duplicating retries.

`dedupe_key` and history `source_entry_key` values are application-generated stable identifiers. The workflow must use the same value when replaying a post or scraper response.

## Initialize and migrate

Run these commands from `deploy/support/` after creating its local `.env` file:

```bash
cp .env.example .env
docker network create transfers_net
docker compose up -d transfers-postgres
docker compose --profile maintenance run --rm transfers-db-migrate
```

The first database start runs `migrate.sql` automatically. The maintenance command is safe to repeat: it holds a PostgreSQL advisory lock and records each applied migration in `app_schema_migrations`.

## Run SQL tests

```bash
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql'
```

The test starts a transaction and rolls it back. It leaves no fixture data behind.

## Digest safety

Reserve a digest delivery and its items in one database transaction before sending the Discord request. Mark it `sending` before the HTTP request, then `sent` only after Discord returns its message ID.

If the worker stops after sending but before recording the response, mark that delivery `unknown` during recovery. Do not automatically retry `sending` or `unknown` deliveries: PostgreSQL cannot determine whether Discord accepted an interrupted request. This conservative rule prevents duplicate Discord digests.
