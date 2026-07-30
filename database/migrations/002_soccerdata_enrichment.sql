ALTER TABLE digest_deliveries
  ADD COLUMN request_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  ADD CONSTRAINT digest_deliveries_request_payload_object
    CHECK (jsonb_typeof(request_payload) = 'object');

CREATE TABLE player_provider_ids (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id bigint NOT NULL REFERENCES players (id) ON DELETE RESTRICT,
  provider text NOT NULL DEFAULT 'sofascore' CHECK (provider = 'sofascore'),
  provider_player_id text NOT NULL CHECK (provider_player_id ~ '^[0-9]+$'),
  canonical_name text NOT NULL CHECK (btrim(canonical_name) <> ''),
  mapping_source text NOT NULL CHECK (mapping_source IN ('automatic', 'manual')),
  match_score numeric(7,3) CHECK (match_score IS NULL OR match_score >= 0),
  match_margin numeric(7,3) CHECK (match_margin IS NULL OR match_margin >= 0),
  resolver_version text NOT NULL CHECK (btrim(resolver_version) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  verified_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (provider, provider_player_id),
  UNIQUE (player_id, provider)
);

CREATE INDEX player_provider_ids_canonical_name_idx
  ON player_provider_ids (provider, lower(canonical_name));

CREATE TABLE player_aliases (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id bigint NOT NULL REFERENCES players (id) ON DELETE CASCADE,
  provider text NOT NULL DEFAULT 'sofascore' CHECK (provider = 'sofascore'),
  alias text NOT NULL CHECK (btrim(alias) <> ''),
  unicode_key text NOT NULL CHECK (btrim(unicode_key) <> ''),
  folded_key text NOT NULL CHECK (btrim(folded_key) <> ''),
  alias_type text NOT NULL CHECK (alias_type IN (
    'provider', 'report', 'manual', 'transliteration'
  )),
  source text NOT NULL CHECK (btrim(source) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (player_id, provider, unicode_key)
);

CREATE INDEX player_aliases_unicode_key_idx
  ON player_aliases (provider, unicode_key) WHERE is_active;
CREATE INDEX player_aliases_folded_key_idx
  ON player_aliases (provider, folded_key) WHERE is_active;

CREATE TABLE player_identity_overrides (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider text NOT NULL DEFAULT 'sofascore' CHECK (provider = 'sofascore'),
  reported_name_key text NOT NULL CHECK (btrim(reported_name_key) <> ''),
  current_club_key text CHECK (current_club_key IS NULL OR btrim(current_club_key) <> ''),
  destination_club_key text
    CHECK (destination_club_key IS NULL OR btrim(destination_club_key) <> ''),
  override_action text NOT NULL CHECK (override_action IN (
    'resolve', 'reject_candidate', 'reject_all'
  )),
  provider_player_id text
    CHECK (provider_player_id IS NULL OR provider_player_id ~ '^[0-9]+$'),
  effective_at timestamptz NOT NULL,
  revoked_at timestamptz,
  reason text NOT NULL CHECK (btrim(reason) <> ''),
  operator_name text NOT NULL CHECK (btrim(operator_name) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (
    (override_action IN ('resolve', 'reject_candidate') AND provider_player_id IS NOT NULL)
    OR (override_action = 'reject_all' AND provider_player_id IS NULL)
  ),
  CHECK (revoked_at IS NULL OR revoked_at >= effective_at)
);

CREATE UNIQUE INDEX player_identity_overrides_active_terminal_idx
  ON player_identity_overrides (
    provider, reported_name_key, current_club_key, destination_club_key
  ) NULLS NOT DISTINCT
  WHERE revoked_at IS NULL AND override_action IN ('resolve', 'reject_all');
CREATE UNIQUE INDEX player_identity_overrides_active_candidate_idx
  ON player_identity_overrides (
    provider, reported_name_key, current_club_key, destination_club_key,
    provider_player_id
  ) NULLS NOT DISTINCT
  WHERE revoked_at IS NULL AND override_action = 'reject_candidate';

CREATE TABLE transfer_report_player_resolutions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfer_report_id bigint NOT NULL UNIQUE
    REFERENCES transfer_reports (id) ON DELETE CASCADE,
  player_provider_id bigint NOT NULL
    REFERENCES player_provider_ids (id) ON DELETE RESTRICT,
  resolution_source text NOT NULL CHECK (resolution_source IN ('automatic', 'manual')),
  match_score numeric(7,3) CHECK (match_score IS NULL OR match_score >= 0),
  match_margin numeric(7,3) CHECK (match_margin IS NULL OR match_margin >= 0),
  resolver_version text NOT NULL CHECK (btrim(resolver_version) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  verified_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX transfer_report_player_resolutions_provider_idx
  ON transfer_report_player_resolutions (player_provider_id);

CREATE TABLE provider_teams (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider text NOT NULL DEFAULT 'sofascore' CHECK (provider = 'sofascore'),
  provider_team_id text NOT NULL CHECK (provider_team_id ~ '^[0-9]+$'),
  canonical_name text NOT NULL CHECK (btrim(canonical_name) <> ''),
  unicode_key text NOT NULL CHECK (btrim(unicode_key) <> ''),
  folded_key text NOT NULL CHECK (btrim(folded_key) <> ''),
  country text,
  category text,
  entity_scope text NOT NULL CHECK (entity_scope IN ('club', 'national', 'unknown')),
  gender text NOT NULL CHECK (gender IN ('men', 'women', 'unknown')),
  age_group text NOT NULL CHECK (age_group IN ('senior', 'youth', 'reserve', 'unknown')),
  raw_metadata_sha256 text NOT NULL CHECK (raw_metadata_sha256 ~ '^[a-f0-9]{64}$'),
  metadata_schema_version text NOT NULL CHECK (btrim(metadata_schema_version) <> ''),
  last_seen_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (provider, provider_team_id)
);

CREATE INDEX provider_teams_unicode_key_idx
  ON provider_teams (provider, unicode_key);
CREATE INDEX provider_teams_folded_key_idx
  ON provider_teams (provider, folded_key);

CREATE TABLE team_aliases (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider_team_id bigint NOT NULL REFERENCES provider_teams (id) ON DELETE CASCADE,
  alias text NOT NULL CHECK (btrim(alias) <> ''),
  unicode_key text NOT NULL CHECK (btrim(unicode_key) <> ''),
  folded_key text NOT NULL CHECK (btrim(folded_key) <> ''),
  country_context text,
  competition_context text,
  alias_source text NOT NULL CHECK (alias_source IN ('automatic', 'manual')),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE UNIQUE INDEX team_aliases_context_unicode_key_idx
  ON team_aliases (
    provider_team_id, country_context, competition_context, unicode_key
  ) NULLS NOT DISTINCT;
CREATE INDEX team_aliases_unicode_lookup_idx
  ON team_aliases (country_context, competition_context, unicode_key)
  WHERE is_active;
CREATE INDEX team_aliases_folded_lookup_idx
  ON team_aliases (country_context, competition_context, folded_key)
  WHERE is_active;

CREATE TABLE provider_competitions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider text NOT NULL DEFAULT 'sofascore' CHECK (provider = 'sofascore'),
  provider_unique_tournament_id text NOT NULL
    CHECK (provider_unique_tournament_id ~ '^[0-9]+$'),
  name text NOT NULL CHECK (btrim(name) <> ''),
  country text,
  category text,
  competition_kind text NOT NULL CHECK (competition_kind IN (
    'domestic_league', 'domestic_cup', 'continental_club',
    'international_club', 'national_team', 'friendly', 'preseason', 'unknown'
  )),
  team_scope text NOT NULL CHECK (team_scope IN ('club', 'national', 'unknown')),
  gender text NOT NULL CHECK (gender IN ('men', 'women', 'unknown')),
  age_group text NOT NULL CHECK (age_group IN ('senior', 'youth', 'reserve', 'unknown')),
  tier smallint CHECK (tier IS NULL OR tier > 0),
  eligibility text NOT NULL CHECK (eligibility IN ('eligible', 'ineligible', 'pending')),
  classification_source text NOT NULL
    CHECK (classification_source IN ('automatic', 'manual')),
  rule_version text NOT NULL CHECK (btrim(rule_version) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  manual_operator text,
  manual_reason text,
  last_seen_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (provider, provider_unique_tournament_id),
  CHECK (
    classification_source <> 'automatic'
    OR eligibility <> 'eligible'
    OR (
      competition_kind = 'domestic_league'
      AND team_scope = 'club'
      AND gender = 'men'
      AND age_group = 'senior'
      AND tier = 1
    )
  )
);

CREATE INDEX provider_competitions_eligibility_kind_idx
  ON provider_competitions (eligibility, competition_kind);
CREATE INDEX provider_competitions_country_tier_idx
  ON provider_competitions (country, tier);

CREATE TABLE provider_seasons (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider_competition_id bigint NOT NULL
    REFERENCES provider_competitions (id) ON DELETE RESTRICT,
  provider_season_id text NOT NULL CHECK (provider_season_id ~ '^[0-9]+$'),
  label text NOT NULL CHECK (btrim(label) <> ''),
  season_year integer,
  starts_on date,
  ends_on date,
  observed_provider_order integer NOT NULL CHECK (observed_provider_order >= 0),
  season_state text NOT NULL CHECK (season_state IN (
    'future', 'active', 'latest_completed', 'historical', 'unknown'
  )),
  is_selected boolean NOT NULL DEFAULT false,
  selection_source text NOT NULL CHECK (selection_source IN ('automatic', 'manual')),
  provider_list_sha256 text NOT NULL CHECK (provider_list_sha256 ~ '^[a-f0-9]{64}$'),
  resolver_version text NOT NULL CHECK (btrim(resolver_version) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  selected_at timestamptz,
  superseded_at timestamptz,
  retrieved_at timestamptz NOT NULL,
  fresh_until timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  manual_reason text,
  manual_operator text,
  UNIQUE (provider_competition_id, provider_season_id),
  CHECK (ends_on IS NULL OR starts_on IS NULL OR ends_on >= starts_on),
  CHECK (NOT is_selected OR season_state IN ('active', 'latest_completed')),
  CHECK (NOT is_selected OR selected_at IS NOT NULL)
);

CREATE UNIQUE INDEX provider_seasons_one_selected_idx
  ON provider_seasons (provider_competition_id) WHERE is_selected;
CREATE INDEX provider_seasons_selected_stale_idx
  ON provider_seasons (fresh_until) WHERE is_selected;

CREATE TABLE team_competition_mappings (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  provider_team_id bigint NOT NULL REFERENCES provider_teams (id) ON DELETE RESTRICT,
  provider_competition_id bigint NOT NULL
    REFERENCES provider_competitions (id) ON DELETE RESTRICT,
  mapping_source text NOT NULL CHECK (mapping_source IN ('automatic', 'manual')),
  rule_version text NOT NULL CHECK (btrim(rule_version) <> ''),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  effective_from timestamptz NOT NULL,
  effective_to timestamptz,
  superseded_at timestamptz,
  verified_at timestamptz NOT NULL,
  fresh_until timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  manual_reason text,
  manual_operator text,
  CHECK (effective_to IS NULL OR effective_to >= effective_from)
);

CREATE UNIQUE INDEX team_competition_mappings_current_idx
  ON team_competition_mappings (provider_team_id) WHERE superseded_at IS NULL;
CREATE INDEX team_competition_mappings_competition_idx
  ON team_competition_mappings (provider_competition_id);
CREATE INDEX team_competition_mappings_freshness_idx
  ON team_competition_mappings (fresh_until) WHERE superseded_at IS NULL;

CREATE TABLE player_profile_snapshots (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_provider_id bigint NOT NULL
    REFERENCES player_provider_ids (id) ON DELETE RESTRICT,
  canonical_name text,
  current_provider_team_id bigint REFERENCES provider_teams (id) ON DELETE RESTRICT,
  nationality text,
  date_of_birth date,
  age smallint CHECK (age IS NULL OR age >= 0),
  primary_position text,
  height_cm smallint CHECK (height_cm IS NULL OR height_cm BETWEEN 100 AND 250),
  preferred_foot text,
  market_value numeric(18,2) CHECK (market_value IS NULL OR market_value >= 0),
  market_value_currency char(3)
    CHECK (market_value_currency IS NULL OR market_value_currency ~ '^[A-Z]{3}$'),
  stable_source_identifier text NOT NULL
    CHECK (btrim(stable_source_identifier) <> ''),
  provider_retrieved_at timestamptz NOT NULL,
  fresh_until timestamptz NOT NULL,
  normalized_schema_version text NOT NULL CHECK (btrim(normalized_schema_version) <> ''),
  resolver_version text NOT NULL CHECK (btrim(resolver_version) <> ''),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  raw_sha256 text NOT NULL CHECK (raw_sha256 ~ '^[a-f0-9]{64}$'),
  raw_cache_key text NOT NULL CHECK (btrim(raw_cache_key) <> ''),
  raw_profile jsonb CHECK (raw_profile IS NULL OR jsonb_typeof(raw_profile) = 'object'),
  derived_fields jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(derived_fields) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (player_provider_id, provider_retrieved_at, content_sha256)
);

CREATE INDEX player_profile_snapshots_current_idx
  ON player_profile_snapshots (player_provider_id, provider_retrieved_at DESC);

CREATE TABLE player_season_stat_snapshots (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_provider_id bigint NOT NULL
    REFERENCES player_provider_ids (id) ON DELETE RESTRICT,
  current_provider_team_id bigint NOT NULL
    REFERENCES provider_teams (id) ON DELETE RESTRICT,
  provider_competition_id bigint NOT NULL
    REFERENCES provider_competitions (id) ON DELETE RESTRICT,
  provider_season_id bigint NOT NULL REFERENCES provider_seasons (id) ON DELETE RESTRICT,
  aggregation_scope text NOT NULL DEFAULT 'selected_domestic_league_all_clubs'
    CHECK (aggregation_scope = 'selected_domestic_league_all_clubs'),
  provider_retrieved_at timestamptz NOT NULL,
  fresh_until timestamptz NOT NULL,
  normalized_schema_version text NOT NULL CHECK (btrim(normalized_schema_version) <> ''),
  resolver_version text NOT NULL CHECK (btrim(resolver_version) <> ''),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  raw_sha256 text NOT NULL CHECK (raw_sha256 ~ '^[a-f0-9]{64}$'),
  raw_cache_key text NOT NULL CHECK (btrim(raw_cache_key) <> ''),
  raw_statistics jsonb
    CHECK (raw_statistics IS NULL OR jsonb_typeof(raw_statistics) = 'object'),
  derived_fields jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(derived_fields) = 'object'),
  appearances integer CHECK (appearances IS NULL OR appearances >= 0),
  starts integer CHECK (starts IS NULL OR starts >= 0),
  minutes_played integer CHECK (minutes_played IS NULL OR minutes_played >= 0),
  minutes_per_appearance numeric(10,2)
    CHECK (minutes_per_appearance IS NULL OR minutes_per_appearance >= 0),
  goals integer CHECK (goals IS NULL OR goals >= 0),
  expected_goals numeric(12,4) CHECK (expected_goals IS NULL OR expected_goals >= 0),
  assists integer CHECK (assists IS NULL OR assists >= 0),
  expected_assists numeric(12,4)
    CHECK (expected_assists IS NULL OR expected_assists >= 0),
  average_rating numeric(5,3)
    CHECK (average_rating IS NULL OR average_rating BETWEEN 0 AND 10),
  yellow_cards integer CHECK (yellow_cards IS NULL OR yellow_cards >= 0),
  red_cards integer CHECK (red_cards IS NULL OR red_cards >= 0),
  goalkeeper_clean_sheets integer
    CHECK (goalkeeper_clean_sheets IS NULL OR goalkeeper_clean_sheets >= 0),
  goalkeeper_saves integer CHECK (goalkeeper_saves IS NULL OR goalkeeper_saves >= 0),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (starts IS NULL OR appearances IS NULL OR starts <= appearances),
  UNIQUE (
    player_provider_id, provider_season_id, aggregation_scope,
    provider_retrieved_at, content_sha256
  )
);

CREATE INDEX player_season_stat_snapshots_current_idx
  ON player_season_stat_snapshots (
    player_provider_id, provider_season_id, provider_retrieved_at DESC
  );

CREATE TABLE player_enrichment_attempts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  request_key text NOT NULL UNIQUE CHECK (btrim(request_key) <> ''),
  batch_request_key text NOT NULL CHECK (btrim(batch_request_key) <> ''),
  item_key text NOT NULL CHECK (btrim(item_key) <> ''),
  workflow_run_id bigint REFERENCES workflow_runs (id) ON DELETE SET NULL,
  transfer_report_id bigint REFERENCES transfer_reports (id) ON DELETE SET NULL,
  player_id bigint REFERENCES players (id) ON DELETE SET NULL,
  player_provider_id bigint REFERENCES player_provider_ids (id) ON DELETE SET NULL,
  status text NOT NULL CHECK (status IN (
    'cache_hit', 'fresh', 'partial', 'unresolved', 'ambiguous', 'deferred',
    'provider_failure', 'rate_limited', 'timeout', 'schema_failure',
    'unsupported_competition', 'missing_season', 'club_conflict', 'unattached'
  )),
  retryable boolean NOT NULL DEFAULT false,
  next_retry_at timestamptz,
  match_score numeric(7,3) CHECK (match_score IS NULL OR match_score >= 0),
  match_margin numeric(7,3) CHECK (match_margin IS NULL OR match_margin >= 0),
  provider_call_count integer NOT NULL DEFAULT 0 CHECK (provider_call_count >= 0),
  cache_hit_count integer NOT NULL DEFAULT 0 CHECK (cache_hit_count >= 0),
  used_stale_profile boolean NOT NULL DEFAULT false,
  used_stale_statistics boolean NOT NULL DEFAULT false,
  request_context jsonb NOT NULL DEFAULT '{}'::jsonb
    CHECK (jsonb_typeof(request_context) = 'object'),
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(evidence) = 'object'),
  error_code text,
  error_fingerprint text,
  error_message text,
  started_at timestamptz NOT NULL,
  completed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (completed_at IS NULL OR completed_at >= started_at)
);

CREATE INDEX player_enrichment_attempts_retry_idx
  ON player_enrichment_attempts (status, next_retry_at) WHERE retryable;
CREATE INDEX player_enrichment_attempts_report_latest_idx
  ON player_enrichment_attempts (transfer_report_id, started_at DESC);
CREATE INDEX player_enrichment_attempts_error_fingerprint_idx
  ON player_enrichment_attempts (error_fingerprint)
  WHERE error_fingerprint IS NOT NULL;

CREATE TRIGGER player_provider_ids_set_updated_at
  BEFORE UPDATE ON player_provider_ids
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER player_aliases_set_updated_at
  BEFORE UPDATE ON player_aliases
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER player_identity_overrides_set_updated_at
  BEFORE UPDATE ON player_identity_overrides
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER provider_teams_set_updated_at
  BEFORE UPDATE ON provider_teams
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER team_aliases_set_updated_at
  BEFORE UPDATE ON team_aliases
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER provider_competitions_set_updated_at
  BEFORE UPDATE ON provider_competitions
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();

CREATE VIEW current_player_enrichment AS
SELECT
  resolution.transfer_report_id,
  resolution.id AS transfer_report_player_resolution_id,
  provider_id.id AS player_provider_id,
  provider_id.player_id,
  provider_id.provider,
  provider_id.provider_player_id,
  provider_id.canonical_name AS provider_canonical_name,
  profile.id AS profile_snapshot_id,
  profile.canonical_name,
  profile.current_provider_team_id,
  profile_team.provider_team_id,
  profile_team.canonical_name AS current_club_name,
  profile.nationality,
  profile.date_of_birth,
  profile.age,
  profile.primary_position,
  profile.height_cm,
  profile.preferred_foot,
  profile.market_value,
  profile.market_value_currency,
  profile.stable_source_identifier,
  profile.provider_retrieved_at AS profile_retrieved_at,
  profile.fresh_until AS profile_fresh_until,
  statistics.id AS statistics_snapshot_id,
  statistics.provider_competition_id,
  competition.provider_unique_tournament_id,
  competition.name AS competition_name,
  statistics.provider_season_id,
  season.provider_season_id AS provider_season_source_id,
  season.label AS season_label,
  season.season_state,
  statistics.aggregation_scope,
  statistics.appearances,
  statistics.starts,
  statistics.minutes_played,
  statistics.minutes_per_appearance,
  statistics.goals,
  statistics.expected_goals,
  statistics.assists,
  statistics.expected_assists,
  statistics.average_rating,
  statistics.yellow_cards,
  statistics.red_cards,
  statistics.goalkeeper_clean_sheets,
  statistics.goalkeeper_saves,
  statistics.provider_retrieved_at AS statistics_retrieved_at,
  statistics.fresh_until AS statistics_fresh_until
FROM transfer_report_player_resolutions AS resolution
JOIN player_provider_ids AS provider_id
  ON provider_id.id = resolution.player_provider_id
LEFT JOIN LATERAL (
  SELECT snapshot.*
  FROM player_profile_snapshots AS snapshot
  WHERE snapshot.player_provider_id = provider_id.id
  ORDER BY snapshot.provider_retrieved_at DESC, snapshot.id DESC
  LIMIT 1
) AS profile ON true
LEFT JOIN provider_teams AS profile_team
  ON profile_team.id = profile.current_provider_team_id
LEFT JOIN LATERAL (
  SELECT snapshot.*
  FROM player_season_stat_snapshots AS snapshot
  JOIN provider_seasons AS selected_season
    ON selected_season.id = snapshot.provider_season_id
   AND selected_season.is_selected
  WHERE snapshot.player_provider_id = provider_id.id
  ORDER BY snapshot.provider_retrieved_at DESC, snapshot.id DESC
  LIMIT 1
) AS statistics ON true
LEFT JOIN provider_competitions AS competition
  ON competition.id = statistics.provider_competition_id
LEFT JOIN provider_seasons AS season
  ON season.id = statistics.provider_season_id;

CREATE FUNCTION app_prune_player_enrichment(
  prune_at timestamptz DEFAULT CURRENT_TIMESTAMP
)
RETURNS TABLE (
  raw_profiles_nulled bigint,
  raw_statistics_nulled bigint,
  attempts_deleted bigint,
  profile_snapshots_deleted bigint,
  statistics_snapshots_deleted bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
  raw_profiles_count bigint;
  raw_statistics_count bigint;
  attempts_count bigint;
  profiles_count bigint;
  statistics_count bigint;
BEGIN
  UPDATE player_profile_snapshots
  SET raw_profile = NULL
  WHERE raw_profile IS NOT NULL
    AND provider_retrieved_at < prune_at - INTERVAL '30 days';
  GET DIAGNOSTICS raw_profiles_count = ROW_COUNT;

  UPDATE player_season_stat_snapshots
  SET raw_statistics = NULL
  WHERE raw_statistics IS NOT NULL
    AND provider_retrieved_at < prune_at - INTERVAL '30 days';
  GET DIAGNOSTICS raw_statistics_count = ROW_COUNT;

  WITH protected_attempts AS (
    SELECT DISTINCT ON (attempt.transfer_report_id) attempt.id
    FROM player_enrichment_attempts AS attempt
    WHERE attempt.transfer_report_id IS NOT NULL
      AND attempt.status IN ('unresolved', 'ambiguous')
      AND NOT EXISTS (
        SELECT 1
        FROM transfer_report_player_resolutions AS resolution
        WHERE resolution.transfer_report_id = attempt.transfer_report_id
      )
      AND NOT EXISTS (
        SELECT 1
        FROM player_identity_overrides AS identity_override
        WHERE identity_override.revoked_at IS NULL
          AND identity_override.override_action IN ('resolve', 'reject_all')
          AND identity_override.provider = 'sofascore'
          AND identity_override.reported_name_key
            = attempt.request_context ->> 'reported_name_key'
          AND identity_override.current_club_key IS NOT DISTINCT FROM
            attempt.request_context ->> 'current_club_key'
          AND identity_override.destination_club_key IS NOT DISTINCT FROM
            attempt.request_context ->> 'destination_club_key'
      )
    ORDER BY attempt.transfer_report_id, attempt.started_at DESC, attempt.id DESC
  )
  DELETE FROM player_enrichment_attempts AS attempt
  WHERE attempt.created_at < prune_at - INTERVAL '90 days'
    AND NOT EXISTS (
      SELECT 1 FROM protected_attempts WHERE protected_attempts.id = attempt.id
    );
  GET DIAGNOSTICS attempts_count = ROW_COUNT;

  WITH newest_profile AS (
    SELECT DISTINCT ON (player_provider_id) id
    FROM player_profile_snapshots
    ORDER BY player_provider_id, provider_retrieved_at DESC, id DESC
  )
  DELETE FROM player_profile_snapshots AS snapshot
  WHERE snapshot.created_at < prune_at - INTERVAL '24 months'
    AND NOT EXISTS (
      SELECT 1 FROM newest_profile WHERE newest_profile.id = snapshot.id
    );
  GET DIAGNOSTICS profiles_count = ROW_COUNT;

  WITH newest_selected_statistics AS (
    SELECT DISTINCT ON (snapshot.player_provider_id) snapshot.id
    FROM player_season_stat_snapshots AS snapshot
    JOIN provider_seasons AS season
      ON season.id = snapshot.provider_season_id
     AND season.is_selected
    ORDER BY snapshot.player_provider_id, snapshot.provider_retrieved_at DESC,
      snapshot.id DESC
  )
  DELETE FROM player_season_stat_snapshots AS snapshot
  WHERE snapshot.created_at < prune_at - INTERVAL '24 months'
    AND NOT EXISTS (
      SELECT 1
      FROM newest_selected_statistics
      WHERE newest_selected_statistics.id = snapshot.id
    );
  GET DIAGNOSTICS statistics_count = ROW_COUNT;

  RETURN QUERY SELECT
    raw_profiles_count,
    raw_statistics_count,
    attempts_count,
    profiles_count,
    statistics_count;
END;
$$;
