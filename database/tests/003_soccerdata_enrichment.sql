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

INSERT INTO player_aliases (
  player_id,
  alias,
  unicode_key,
  folded_key,
  alias_type,
  source,
  evidence
)
VALUES (
  :canonical_player_id,
  'Canonical P.',
  'canonical p',
  'canonical p',
  'manual',
  'fixture',
  '{"source":"fixture"}'::jsonb
);

INSERT INTO player_identity_overrides (
  reported_name_key,
  current_club_key,
  destination_club_key,
  override_action,
  provider_player_id,
  effective_at,
  reason,
  operator_name,
  evidence
)
VALUES (
  'common name',
  'current fc',
  NULL,
  'reject_candidate',
  '1002',
  '2026-07-30 00:00:00+00',
  'fixture rejection',
  'test operator',
  '{"source":"fixture"}'::jsonb
);

INSERT INTO team_aliases (
  provider_team_id,
  alias,
  unicode_key,
  folded_key,
  country_context,
  competition_context,
  alias_source,
  evidence
)
VALUES (
  :provider_team_id,
  'Current',
  'current',
  'current',
  'England',
  'Test Premier League',
  'manual',
  '{"source":"fixture"}'::jsonb
);

INSERT INTO team_competition_mappings (
  provider_team_id,
  provider_competition_id,
  mapping_source,
  rule_version,
  evidence,
  effective_from,
  verified_at,
  fresh_until
)
VALUES (
  :provider_team_id,
  :competition_id,
  'automatic',
  'competition-v1',
  '{"source":"fixture"}'::jsonb,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00',
  '2026-07-31 00:00:00+00'
);

SELECT
  (SELECT count(*) FROM transfer_report_revisions) AS revisions_before_stats,
  (SELECT count(*) FROM digest_deliveries) AS deliveries_before_stats
\gset

INSERT INTO player_profile_snapshots (
  player_provider_id,
  canonical_name,
  current_provider_team_id,
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
  'Canonical Player Updated',
  :provider_team_id,
  'sofascore:player:1001',
  '2026-07-30 01:00:00+00',
  '2026-07-31 01:00:00+00',
  'profile-v1',
  'identity-v1',
  repeat('1', 64),
  repeat('2', 64),
  'profile-1001-later',
  '{}'::jsonb
);

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
  '2026-07-30 01:00:00+00',
  '2026-07-30 13:00:00+00',
  'statistics-v1',
  'season-v1',
  repeat('3', 64),
  repeat('4', 64),
  'statistics-1001-3001-4001-later',
  '{}'::jsonb,
  3,
  3,
  240,
  80,
  2
);

-- Representative negative values exercise every constraint family.
DO $$
BEGIN
  BEGIN
    INSERT INTO player_provider_ids (
      player_id, provider_player_id, canonical_name, mapping_source,
      resolver_version, verified_at, last_seen_at
    )
    SELECT id, 'not-decimal', 'Invalid', 'automatic', 'identity-v1',
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
    FROM players
    WHERE identity_key = 'enrichment-other-player';
    RAISE EXCEPTION 'invalid provider ID was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO player_identity_overrides (
      reported_name_key, override_action, provider_player_id, effective_at,
      reason, operator_name
    )
    VALUES (
      'invalid override', 'reject_all', '1001', CURRENT_TIMESTAMP,
      'fixture', 'test operator'
    );
    RAISE EXCEPTION 'invalid reject_all override was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO provider_competitions (
      provider_unique_tournament_id, name, competition_kind, team_scope,
      gender, age_group, tier, eligibility, classification_source,
      rule_version, last_seen_at
    )
    VALUES (
      '3999', 'Invalid Cup', 'domestic_cup', 'club', 'men', 'senior', 1,
      'eligible', 'automatic', 'competition-v1', CURRENT_TIMESTAMP
    );
    RAISE EXCEPTION 'invalid automatic eligible competition was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO provider_seasons (
      provider_competition_id, provider_season_id, label,
      observed_provider_order, season_state, is_selected, selection_source,
      provider_list_sha256, resolver_version, selected_at, retrieved_at,
      fresh_until
    )
    SELECT id, '4999', 'Future', 0, 'future', true, 'automatic',
      repeat('5', 64), 'season-v1', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP,
      CURRENT_TIMESTAMP + INTERVAL '1 day'
    FROM provider_competitions
    WHERE provider_unique_tournament_id = '3001';
    RAISE EXCEPTION 'future selected season was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO player_season_stat_snapshots (
      player_provider_id, current_provider_team_id, provider_competition_id,
      provider_season_id, provider_retrieved_at, fresh_until,
      normalized_schema_version, resolver_version, content_sha256, raw_sha256,
      raw_cache_key, appearances, starts, average_rating
    )
    SELECT provider_id.id, team.id, competition.id, season.id,
      CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + INTERVAL '1 hour',
      'statistics-v1', 'season-v1', repeat('6', 64), repeat('7', 64),
      'invalid-statistics', 1, 2, 11
    FROM player_provider_ids AS provider_id
    CROSS JOIN provider_teams AS team
    CROSS JOIN provider_competitions AS competition
    CROSS JOIN provider_seasons AS season
    WHERE provider_id.provider_player_id = '1001'
      AND team.provider_team_id = '2001'
      AND competition.provider_unique_tournament_id = '3001'
      AND season.provider_season_id = '4001';
    RAISE EXCEPTION 'invalid statistics ranges were accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO player_enrichment_attempts (
      request_key, batch_request_key, item_key, status, started_at, completed_at
    )
    VALUES (
      'invalid-time', 'invalid', 'invalid', 'fresh',
      '2026-07-30 01:00:00+00', '2026-07-30 00:00:00+00'
    );
    RAISE EXCEPTION 'invalid attempt timestamps were accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    UPDATE digest_deliveries
    SET request_payload = '[]'::jsonb
    WHERE idempotency_key = 'enrichment-frozen-payload';
    RAISE EXCEPTION 'non-object frozen payload was accepted';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    DELETE FROM players
    WHERE identity_key = 'enrichment-canonical-player';
    RAISE EXCEPTION 'provider identity RESTRICT behavior was not enforced';
  EXCEPTION WHEN foreign_key_violation THEN NULL;
  END;
END
$$;

SELECT CASE
  WHEN (
    SELECT count(*)
    FROM information_schema.tables
    WHERE table_schema = 'public'
      AND table_name IN (
        'player_provider_ids',
        'player_aliases',
        'player_identity_overrides',
        'transfer_report_player_resolutions',
        'provider_teams',
        'team_aliases',
        'provider_competitions',
        'provider_seasons',
        'team_competition_mappings',
        'player_profile_snapshots',
        'player_season_stat_snapshots',
        'player_enrichment_attempts'
      )
  ) = 12
   AND (
     SELECT count(*)
     FROM pg_indexes
     WHERE schemaname = 'public'
       AND indexname IN (
         'player_provider_ids_canonical_name_idx',
         'player_aliases_unicode_key_idx',
         'player_aliases_folded_key_idx',
         'player_identity_overrides_active_terminal_idx',
         'player_identity_overrides_active_candidate_idx',
         'transfer_report_player_resolutions_provider_idx',
         'provider_teams_unicode_key_idx',
         'provider_teams_folded_key_idx',
         'team_aliases_context_unicode_key_idx',
         'team_aliases_unicode_lookup_idx',
         'team_aliases_folded_lookup_idx',
         'provider_competitions_eligibility_kind_idx',
         'provider_competitions_country_tier_idx',
         'provider_seasons_one_selected_idx',
         'provider_seasons_selected_stale_idx',
         'team_competition_mappings_current_idx',
         'team_competition_mappings_competition_idx',
         'team_competition_mappings_freshness_idx',
         'player_profile_snapshots_current_idx',
         'player_season_stat_snapshots_current_idx',
         'player_enrichment_attempts_retry_idx',
         'player_enrichment_attempts_report_latest_idx',
         'player_enrichment_attempts_error_fingerprint_idx'
       )
   ) = 23
   AND EXISTS (
     SELECT 1
     FROM information_schema.views
     WHERE table_schema = 'public'
       AND table_name = 'current_player_enrichment'
   )
   AND to_regprocedure('app_prune_player_enrichment(timestamp with time zone)')
     IS NOT NULL
  THEN 'true'
  ELSE 'false'
END AS enrichment_catalog_complete \gset

\if :enrichment_catalog_complete
\else
  \echo 'Enrichment table, index, view, or prune function catalog assertion failed'
  \quit 3
\endif

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
   ) = 2
   AND (
     SELECT count(*)
     FROM player_season_stat_snapshots
     WHERE player_provider_id = :provider_player_id
       AND provider_season_id = :season_id
   ) = 2
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
   AND (
     SELECT canonical_name = 'Canonical Player Updated'
       AND appearances = 3
     FROM current_player_enrichment
     WHERE transfer_report_id = :report_id
   )
   AND (SELECT count(*) FROM player_aliases) = 1
   AND (SELECT count(*) FROM player_identity_overrides) = 1
   AND (SELECT count(*) FROM team_aliases) = 1
   AND (SELECT count(*) FROM team_competition_mappings) = 1
   AND (SELECT count(*) FROM transfer_report_revisions) = :revisions_before_stats
   AND (SELECT count(*) FROM digest_deliveries) = :deliveries_before_stats
  THEN 'true'
  ELSE 'false'
END AS enrichment_restart_safe \gset

\if :enrichment_restart_safe
\else
  \echo 'Enrichment uniqueness, replay, canonical-player, view, or frozen-payload assertion failed'
  \quit 3
\endif

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
  'cleanup-common-name|current-fc|destination-fc',
  :other_player_id,
  'Common Name',
  'Current FC',
  'Destination FC',
  'rumor',
  0.700,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset unresolved_report_

INSERT INTO player_enrichment_attempts (
  request_key, batch_request_key, item_key, transfer_report_id, status,
  request_context, evidence, started_at, created_at
)
VALUES (
  'cleanup-protected', 'cleanup', 'common-name', :unresolved_report_id,
  'ambiguous', '{"reported_name_key":"common name"}'::jsonb, '{}'::jsonb,
  '2026-07-30 00:00:00+00',
  '2027-01-01 00:00:00+00'::timestamptz - INTERVAL '91 days'
), (
  'cleanup-boundary', 'cleanup', 'boundary', NULL,
  'provider_failure', '{}'::jsonb, '{}'::jsonb,
  '2026-10-03 00:00:00+00',
  '2027-01-01 00:00:00+00'::timestamptz - INTERVAL '90 days'
), (
  'cleanup-expired', 'cleanup', 'expired', NULL,
  'provider_failure', '{}'::jsonb, '{}'::jsonb,
  '2026-10-02 23:59:59+00',
  '2027-01-01 00:00:00+00'::timestamptz - INTERVAL '90 days 1 second'
);

SELECT *
FROM app_prune_player_enrichment('2027-01-01 00:00:00+00')
\gset prune_

SELECT CASE
  WHEN :prune_raw_profiles_nulled >= 1
   AND :prune_raw_statistics_nulled >= 1
   AND :prune_attempts_deleted >= 1
   AND :prune_profile_snapshots_deleted = 0
   AND :prune_statistics_snapshots_deleted = 0
   AND NOT EXISTS (
     SELECT 1 FROM player_enrichment_attempts
     WHERE request_key = 'cleanup-expired'
   )
   AND EXISTS (
     SELECT 1 FROM player_enrichment_attempts
     WHERE request_key = 'cleanup-boundary'
   )
   AND EXISTS (
     SELECT 1 FROM player_enrichment_attempts
     WHERE request_key = 'cleanup-protected'
       AND transfer_report_id = :unresolved_report_id
   )
   AND (
     SELECT player_id FROM transfer_reports WHERE id = :unresolved_report_id
   ) = :other_player_id
  THEN 'true'
  ELSE 'false'
END AS enrichment_cleanup_safe \gset

\if :enrichment_cleanup_safe
\else
  \echo 'Enrichment cleanup boundary, unresolved exception, or common-name isolation failed'
  \quit 3
\endif

ROLLBACK;
