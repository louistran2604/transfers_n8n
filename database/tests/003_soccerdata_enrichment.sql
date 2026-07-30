\set ON_ERROR_STOP on

BEGIN;

SELECT CASE
  WHEN (
    SELECT count(*)
    FROM app_schema_migrations
    WHERE version = '002_soccerdata_enrichment'
  ) = 1 THEN 'true'
  ELSE 'false'
END AS migration_ready \gset

\if :migration_ready
\else
  \echo 'Migration 002_soccerdata_enrichment has not been applied exactly once'
  \quit 3
\endif

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('enrichment-canonical-player', 'Canonical Player', 'canonical player')
RETURNING id \gset canonical_player_

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('enrichment-other-player', 'Other Player', 'other player')
RETURNING id \gset other_player_

INSERT INTO transfer_reports (
  dedupe_key,
  player_id,
  reported_player_name,
  current_club_name,
  destination_club_name,
  classification,
  confidence,
  first_reported_at,
  last_reported_at
)
VALUES (
  'enrichment-canonical-player|current-fc|destination-fc',
  :canonical_player_id,
  'Canonical Player',
  'Current FC',
  'Destination FC',
  'rumor',
  0.800,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset report_

INSERT INTO player_provider_ids (
  player_id,
  provider_player_id,
  canonical_name,
  mapping_source,
  match_score,
  match_margin,
  resolver_version,
  evidence,
  verified_at,
  last_seen_at
)
VALUES (
  :canonical_player_id,
  '1001',
  'Canonical Player',
  'automatic',
  100,
  20,
  'identity-v1',
  '{"source":"fixture"}'::jsonb,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset provider_player_

-- A provider player cannot be attached to a second canonical player.
INSERT INTO player_provider_ids (
  player_id,
  provider_player_id,
  canonical_name,
  mapping_source,
  resolver_version,
  evidence,
  verified_at,
  last_seen_at
)
VALUES (
  :other_player_id,
  '1001',
  'Wrong Duplicate',
  'automatic',
  'identity-v1',
  '{}'::jsonb,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00'
)
ON CONFLICT DO NOTHING;

INSERT INTO player_provider_ids (
  player_id,
  provider_player_id,
  canonical_name,
  mapping_source,
  resolver_version,
  evidence,
  verified_at,
  last_seen_at
)
VALUES (
  :other_player_id,
  '1002',
  'Other Player',
  'automatic',
  'identity-v1',
  '{}'::jsonb,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset other_provider_player_

INSERT INTO transfer_report_player_resolutions (
  transfer_report_id,
  player_provider_id,
  resolution_source,
  match_score,
  match_margin,
  resolver_version,
  evidence,
  verified_at
)
VALUES (
  :report_id,
  :provider_player_id,
  'automatic',
  100,
  20,
  'identity-v1',
  '{}'::jsonb,
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset resolution_

-- A replay or competing result cannot replace the report's exact resolution.
INSERT INTO transfer_report_player_resolutions (
  transfer_report_id,
  player_provider_id,
  resolution_source,
  resolver_version,
  evidence,
  verified_at
)
VALUES (
  :report_id,
  :other_provider_player_id,
  'automatic',
  'identity-v1',
  '{}'::jsonb,
  '2026-07-30 00:00:01+00'
)
ON CONFLICT (transfer_report_id) DO NOTHING;

INSERT INTO provider_teams (
  provider_team_id,
  canonical_name,
  unicode_key,
  folded_key,
  country,
  entity_scope,
  gender,
  age_group,
  raw_metadata_sha256,
  metadata_schema_version,
  last_seen_at
)
VALUES (
  '2001',
  'Current FC',
  'current fc',
  'current fc',
  'England',
  'club',
  'men',
  'senior',
  repeat('a', 64),
  'team-v1',
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset provider_team_

INSERT INTO provider_competitions (
  provider_unique_tournament_id,
  name,
  country,
  competition_kind,
  team_scope,
  gender,
  age_group,
  tier,
  eligibility,
  classification_source,
  rule_version,
  evidence,
  last_seen_at
)
VALUES (
  '3001',
  'Test Premier League',
  'England',
  'domestic_league',
  'club',
  'men',
  'senior',
  1,
  'eligible',
  'automatic',
  'competition-v1',
  '{}'::jsonb,
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset competition_

INSERT INTO provider_seasons (
  provider_competition_id,
  provider_season_id,
  label,
  season_year,
  observed_provider_order,
  season_state,
  is_selected,
  selection_source,
  provider_list_sha256,
  resolver_version,
  evidence,
  selected_at,
  retrieved_at,
  fresh_until
)
VALUES (
  :competition_id,
  '4001',
  '2026/27',
  2026,
  0,
  'active',
  true,
  'automatic',
  repeat('b', 64),
  'season-v1',
  '{}'::jsonb,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00',
  '2026-07-31 00:00:00+00'
)
RETURNING id \gset season_

INSERT INTO player_profile_snapshots (
  player_provider_id,
  canonical_name,
  current_provider_team_id,
  nationality,
  date_of_birth,
  age,
  primary_position,
  height_cm,
  preferred_foot,
  market_value,
  market_value_currency,
  stable_source_identifier,
  provider_retrieved_at,
  fresh_until,
  normalized_schema_version,
  resolver_version,
  content_sha256,
  raw_sha256,
  raw_cache_key,
  raw_profile,
  derived_fields
)
VALUES (
  :provider_player_id,
  'Canonical Player',
  :provider_team_id,
  'England',
  '2000-01-01',
  26,
  'Forward',
  180,
  'right',
  1000000,
  'EUR',
  'sofascore:player:1001',
  '2026-07-30 00:00:00+00',
  '2026-07-31 00:00:00+00',
  'profile-v1',
  'identity-v1',
  repeat('c', 64),
  repeat('d', 64),
  'profile-1001',
  '{"player":{"id":1001}}'::jsonb,
  '{"age":{"date_of_birth":"2000-01-01"}}'::jsonb
)
ON CONFLICT DO NOTHING;

INSERT INTO player_profile_snapshots (
  player_provider_id,
  canonical_name,
  stable_source_identifier,
  provider_retrieved_at,
  fresh_until,
  normalized_schema_version,
  resolver_version,
  content_sha256,
  raw_sha256,
  raw_cache_key,
  derived_fields
)
VALUES (
  :provider_player_id,
  'Canonical Player',
  'sofascore:player:1001',
  '2026-07-30 00:00:00+00',
  '2026-07-31 00:00:00+00',
  'profile-v1',
  'identity-v1',
  repeat('c', 64),
  repeat('d', 64),
  'profile-1001',
  '{}'::jsonb
)
ON CONFLICT DO NOTHING;

INSERT INTO player_season_stat_snapshots (
  player_provider_id,
  current_provider_team_id,
  provider_competition_id,
  provider_season_id,
  provider_retrieved_at,
  fresh_until,
  normalized_schema_version,
  resolver_version,
  content_sha256,
  raw_sha256,
  raw_cache_key,
  raw_statistics,
  derived_fields,
  appearances,
  starts,
  minutes_played,
  minutes_per_appearance,
  goals
)
VALUES (
  :provider_player_id,
  :provider_team_id,
  :competition_id,
  :season_id,
  '2026-07-30 00:00:00+00',
  '2026-07-30 12:00:00+00',
  'statistics-v1',
  'season-v1',
  repeat('e', 64),
  repeat('f', 64),
  'statistics-1001-3001-4001',
  '{"statistics":{"appearances":2}}'::jsonb,
  '{"minutes_per_appearance":{"minutes":160,"appearances":2}}'::jsonb,
  2,
  2,
  160,
  80,
  1
)
ON CONFLICT DO NOTHING;

INSERT INTO player_season_stat_snapshots (
  player_provider_id,
  current_provider_team_id,
  provider_competition_id,
  provider_season_id,
  provider_retrieved_at,
  fresh_until,
  normalized_schema_version,
  resolver_version,
  content_sha256,
  raw_sha256,
  raw_cache_key,
  derived_fields
)
VALUES (
  :provider_player_id,
  :provider_team_id,
  :competition_id,
  :season_id,
  '2026-07-30 00:00:00+00',
  '2026-07-30 12:00:00+00',
  'statistics-v1',
  'season-v1',
  repeat('e', 64),
  repeat('f', 64),
  'statistics-1001-3001-4001',
  '{}'::jsonb
)
ON CONFLICT DO NOTHING;

INSERT INTO player_enrichment_attempts (
  request_key,
  batch_request_key,
  item_key,
  transfer_report_id,
  player_id,
  player_provider_id,
  status,
  provider_call_count,
  cache_hit_count,
  request_context,
  evidence,
  started_at,
  completed_at
)
VALUES (
  'batch-1:report-1',
  'batch-1',
  'player-1001',
  :report_id,
  :canonical_player_id,
  :provider_player_id,
  'fresh',
  4,
  0,
  '{"reported_name_key":"canonical player"}'::jsonb,
  '{}'::jsonb,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:10+00'
)
ON CONFLICT (request_key) DO NOTHING;

INSERT INTO player_enrichment_attempts (
  request_key,
  batch_request_key,
  item_key,
  status,
  request_context,
  evidence,
  started_at
)
VALUES (
  'batch-1:report-1',
  'batch-1',
  'player-1001',
  'provider_failure',
  '{}'::jsonb,
  '{}'::jsonb,
  '2026-07-30 00:00:20+00'
)
ON CONFLICT (request_key) DO NOTHING;

INSERT INTO digest_deliveries (
  idempotency_key,
  channel_key,
  window_started_at,
  window_ended_at,
  request_payload
)
VALUES (
  'enrichment-frozen-payload',
  'transfers',
  '2026-07-30 00:00:00+00',
  '2026-07-30 06:00:00+00',
  '{"content":"first reservation"}'::jsonb
)
RETURNING id \gset delivery_

INSERT INTO digest_deliveries (
  idempotency_key,
  channel_key,
  window_started_at,
  window_ended_at,
  request_payload
)
VALUES (
  'enrichment-frozen-payload',
  'transfers',
  '2026-07-30 00:00:00+00',
  '2026-07-30 06:00:00+00',
  '{"content":"mutated retry"}'::jsonb
)
ON CONFLICT (idempotency_key) DO UPDATE
SET updated_at = CURRENT_TIMESTAMP;

SELECT CASE
  WHEN (SELECT count(*) FROM player_provider_ids WHERE provider_player_id = '1001') = 1
   AND (SELECT player_id FROM player_provider_ids WHERE id = :provider_player_id)
     = :canonical_player_id
   AND (SELECT player_id FROM transfer_reports WHERE id = :report_id)
     = :canonical_player_id
   AND (
     SELECT player_provider_id
     FROM transfer_report_player_resolutions
     WHERE transfer_report_id = :report_id
   ) = :provider_player_id
   AND (
     SELECT count(*)
     FROM transfer_report_player_resolutions
     WHERE transfer_report_id = :report_id
   ) = 1
   AND (
     SELECT count(*)
     FROM player_profile_snapshots
     WHERE player_provider_id = :provider_player_id
   ) = 1
   AND (
     SELECT count(*)
     FROM player_season_stat_snapshots
     WHERE player_provider_id = :provider_player_id
       AND provider_season_id = :season_id
   ) = 1
   AND (
     SELECT count(*)
     FROM player_enrichment_attempts
     WHERE request_key = 'batch-1:report-1'
   ) = 1
   AND (
     SELECT request_payload ->> 'content'
     FROM digest_deliveries
     WHERE id = :delivery_id
   ) = 'first reservation'
   AND (
     SELECT profile_snapshot_id IS NOT NULL
       AND statistics_snapshot_id IS NOT NULL
       AND player_id = :canonical_player_id
     FROM current_player_enrichment
     WHERE transfer_report_id = :report_id
   )
  THEN 'true'
  ELSE 'false'
END AS enrichment_restart_safe \gset

\if :enrichment_restart_safe
\else
  \echo 'Enrichment uniqueness, replay, canonical-player, view, or frozen-payload assertion failed'
  \quit 3
\endif

ROLLBACK;
