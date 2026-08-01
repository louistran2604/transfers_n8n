#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compose_file="$root_dir/tests/e2e/compose.yaml"

cleanup() {
  docker compose -f "$compose_file" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker compose -f "$compose_file" up -d --wait postgres mock-services sofascore-enrichment
docker compose -f "$compose_file" exec -T postgres psql --username transfers_e2e --dbname transfers_e2e --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql
docker compose -f "$compose_file" exec -T postgres psql --username transfers_e2e --dbname transfers_e2e --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql
docker compose -f "$compose_file" exec -T postgres psql --username transfers_e2e --dbname transfers_e2e --set ON_ERROR_STOP=1 --file /database/tests/003_soccerdata_enrichment.sql
docker compose -f "$compose_file" exec -T postgres psql --username transfers_e2e --dbname transfers_e2e --set ON_ERROR_STOP=1 --file /database/tests/004_enrichment_rollback_compatibility.sql
docker compose -f "$compose_file" run --rm --no-deps n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose -f "$compose_file" run --rm --no-deps n8n import:workflow --input=/workflows/football-transfer-monitor.json
docker compose -f "$compose_file" up -d --wait n8n
node "$root_dir/tests/e2e/scenario.mjs"

docker compose -f "$compose_file" exec -T postgres psql \
  --username transfers_e2e --dbname transfers_e2e --set ON_ERROR_STOP=1 <<'SQL'
BEGIN;

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('e2e-sofascore-player-9001', 'E2E Player', 'e2e player')
RETURNING id \gset player_

INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name,
  destination_club_name, classification, confidence, first_reported_at,
  last_reported_at
)
VALUES (
  'e2e-player|current|destination', :player_id, 'E2E Player', 'Current FC',
  'Destination FC', 'rumor', 0.8, '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset report_

INSERT INTO transfer_report_revisions (
  transfer_report_id, revision_number, content_sha256, snapshot
)
VALUES (:report_id, 1, repeat('a', 64), '{"transfer":"frozen"}'::jsonb)
RETURNING id \gset revision_

INSERT INTO player_provider_ids (
  player_id, provider_player_id, canonical_name, mapping_source,
  resolver_version, verified_at, last_seen_at
)
VALUES (
  :player_id, '9001', 'E2E Player', 'automatic', 'identity-v1',
  '2026-07-30 00:00:00+00', '2026-07-30 00:00:00+00'
)
RETURNING id \gset provider_player_

INSERT INTO provider_teams (
  provider_team_id, canonical_name, unicode_key, folded_key, entity_scope,
  gender, age_group, raw_metadata_sha256, metadata_schema_version, last_seen_at
)
VALUES (
  '9002', 'Current FC', 'current fc', 'current fc', 'club', 'men', 'senior',
  repeat('b', 64), 'team-v1', '2026-07-30 00:00:00+00'
)
RETURNING id \gset team_

INSERT INTO provider_competitions (
  provider_unique_tournament_id, name, competition_kind, team_scope, gender,
  age_group, tier, eligibility, classification_source, rule_version, last_seen_at
)
VALUES (
  '9003', 'E2E League', 'domestic_league', 'club', 'men', 'senior', 1,
  'eligible', 'automatic', 'competition-v1', '2026-07-30 00:00:00+00'
)
RETURNING id \gset competition_

INSERT INTO provider_seasons (
  provider_competition_id, provider_season_id, label, observed_provider_order,
  season_state, is_selected, selection_source, provider_list_sha256,
  resolver_version, selected_at, retrieved_at, fresh_until
)
VALUES (
  :competition_id, '9004', '2025/26', 0, 'latest_completed', true, 'automatic',
  repeat('c', 64), 'season-v1', '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00', '2026-07-31 00:00:00+00'
)
RETURNING id \gset season_

INSERT INTO player_enrichment_attempts (
  request_key, batch_request_key, item_key, transfer_report_id, player_id,
  player_provider_id, status, request_context, started_at, completed_at
)
VALUES (
  'e2e-batch:item', 'e2e-batch', 'provider:9001', :report_id, :player_id,
  :provider_player_id, 'provider_failure', '{"mode":"active"}'::jsonb,
  '2026-07-30 00:00:00+00', '2026-07-30 00:00:01+00'
)
ON CONFLICT (request_key) DO NOTHING;

INSERT INTO player_enrichment_attempts (
  request_key, batch_request_key, item_key, status, request_context, started_at
)
VALUES (
  'e2e-batch:item', 'e2e-batch', 'provider:9001', 'fresh', '{}'::jsonb,
  '2026-07-30 00:00:02+00'
)
ON CONFLICT (request_key) DO NOTHING;

INSERT INTO digest_deliveries (
  idempotency_key, channel_key, window_started_at, window_ended_at, request_payload
)
VALUES (
  'e2e-transfer-only', 'transfers', '2026-07-30 00:00:00+00',
  '2026-07-30 06:00:00+00', '{"content":"transfer-only"}'::jsonb
)
RETURNING id \gset delivery_

INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
VALUES (:delivery_id, :revision_id, 1)
ON CONFLICT DO NOTHING;

INSERT INTO digest_deliveries (
  idempotency_key, channel_key, window_started_at, window_ended_at, request_payload
)
VALUES (
  'e2e-transfer-only', 'transfers', '2026-07-30 00:00:00+00',
  '2026-07-30 06:00:00+00', '{"content":"mutated replay"}'::jsonb
)
ON CONFLICT (idempotency_key) DO UPDATE SET updated_at = CURRENT_TIMESTAMP;

INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
VALUES (:delivery_id, :revision_id, 1)
ON CONFLICT DO NOTHING;

INSERT INTO player_season_stat_snapshots (
  player_provider_id, current_provider_team_id, provider_competition_id,
  provider_season_id, provider_retrieved_at, fresh_until,
  normalized_schema_version, resolver_version, content_sha256, raw_sha256,
  raw_cache_key, appearances
)
VALUES (
  :provider_player_id, :team_id, :competition_id, :season_id,
  '2026-07-30 01:00:00+00', '2026-07-30 13:00:00+00', 'statistics-v1',
  'season-v1', repeat('d', 64), repeat('e', 64), 'e2e-statistics-1', 2
), (
  :provider_player_id, :team_id, :competition_id, :season_id,
  '2026-07-30 02:00:00+00', '2026-07-30 14:00:00+00', 'statistics-v1',
  'season-v1', repeat('f', 64), repeat('0', 64), 'e2e-statistics-2', 3
);

SELECT CASE WHEN
  (SELECT count(*) FROM player_enrichment_attempts WHERE request_key = 'e2e-batch:item') = 1
  AND (SELECT count(*) FROM digest_deliveries WHERE idempotency_key = 'e2e-transfer-only') = 1
  AND (SELECT count(*) FROM digest_items WHERE digest_delivery_id = :delivery_id) = 1
  AND (SELECT request_payload ->> 'content' FROM digest_deliveries WHERE id = :delivery_id) = 'transfer-only'
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :report_id) = 1
  THEN 'true' ELSE 'false' END AS data_flow_safe \gset

\if :data_flow_safe
\else
  \echo 'E2E persistence, replay, payload freeze, or no-revision invariant failed'
  \quit 3
\endif

ROLLBACK;
SQL
