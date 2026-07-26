BEGIN;

CREATE OR REPLACE FUNCTION app_set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = CURRENT_TIMESTAMP;
  RETURN NEW;
END;
$$;

CREATE TABLE source_accounts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  platform text NOT NULL DEFAULT 'x' CHECK (platform = 'x'),
  external_account_id text NOT NULL CHECK (external_account_id ~ '^[0-9]+$'),
  username text NOT NULL CHECK (username ~ '^[A-Za-z0-9_]{1,15}$'),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  account_type text NOT NULL CHECK (account_type IN ('individual', 'organization')),
  is_official boolean NOT NULL DEFAULT false,
  priority_rank smallint NOT NULL CHECK (priority_rank BETWEEN 1 AND 100),
  reliability_score numeric(4,3) NOT NULL DEFAULT 0.500
    CHECK (reliability_score BETWEEN 0 AND 1),
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (platform, external_account_id)
);

CREATE UNIQUE INDEX source_accounts_platform_username_unique
  ON source_accounts (platform, lower(username));

CREATE TABLE raw_posts (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_account_id bigint NOT NULL REFERENCES source_accounts (id) ON DELETE RESTRICT,
  platform text NOT NULL DEFAULT 'x' CHECK (platform = 'x'),
  external_post_id text NOT NULL CHECK (external_post_id ~ '^[0-9]+$'),
  post_url text NOT NULL CHECK (post_url ~ '^https://'),
  content text NOT NULL CHECK (btrim(content) <> ''),
  content_sha256 text CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  posted_at timestamptz NOT NULL,
  collected_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  raw_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(raw_payload) = 'object'),
  processing_state text NOT NULL DEFAULT 'pending'
    CHECK (processing_state IN ('pending', 'classified', 'merged', 'ignored', 'failed')),
  classified_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (platform, external_post_id)
);

CREATE INDEX raw_posts_source_account_posted_at_idx
  ON raw_posts (source_account_id, posted_at DESC);
CREATE INDEX raw_posts_processing_state_collected_at_idx
  ON raw_posts (processing_state, collected_at)
  WHERE processing_state IN ('pending', 'failed');

CREATE TABLE players (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  identity_key text NOT NULL UNIQUE CHECK (btrim(identity_key) <> ''),
  display_name text NOT NULL CHECK (btrim(display_name) <> ''),
  normalized_name text NOT NULL CHECK (btrim(normalized_name) <> ''),
  birth_date date,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX players_normalized_name_idx ON players (normalized_name);

CREATE TABLE transfermarkt_profiles (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  player_id bigint NOT NULL UNIQUE REFERENCES players (id) ON DELETE CASCADE,
  transfermarkt_player_id text NOT NULL UNIQUE CHECK (transfermarkt_player_id ~ '^[0-9]+$'),
  profile_url text NOT NULL UNIQUE CHECK (profile_url ~ '^https://'),
  birthplace text,
  nationalities text[] NOT NULL DEFAULT ARRAY[]::text[],
  height_cm smallint CHECK (height_cm BETWEEN 100 AND 250),
  positions text[] NOT NULL DEFAULT ARRAY[]::text[],
  preferred_foot text CHECK (preferred_foot IN ('left', 'right', 'both', 'unknown')),
  current_club_name text,
  squad_number text,
  joined_on date,
  contract_expires_on date,
  current_market_value_amount numeric(14,2)
    CHECK (current_market_value_amount IS NULL OR current_market_value_amount >= 0),
  current_market_value_currency char(3)
    CHECK (current_market_value_currency IS NULL OR current_market_value_currency ~ '^[A-Z]{3}$'),
  current_market_value_as_of date,
  last_scraped_at timestamptz,
  raw_profile jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(raw_profile) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE player_transfer_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfermarkt_profile_id bigint NOT NULL REFERENCES transfermarkt_profiles (id) ON DELETE CASCADE,
  source_entry_key text NOT NULL CHECK (btrim(source_entry_key) <> ''),
  transfer_date date,
  from_club_name text,
  to_club_name text,
  market_value_amount numeric(14,2)
    CHECK (market_value_amount IS NULL OR market_value_amount >= 0),
  market_value_currency char(3)
    CHECK (market_value_currency IS NULL OR market_value_currency ~ '^[A-Z]{3}$'),
  reported_fee text,
  transfer_type text,
  raw_entry jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(raw_entry) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (transfermarkt_profile_id, source_entry_key)
);

CREATE INDEX player_transfer_history_profile_date_idx
  ON player_transfer_history (transfermarkt_profile_id, transfer_date DESC NULLS LAST);

CREATE TABLE player_youth_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfermarkt_profile_id bigint NOT NULL REFERENCES transfermarkt_profiles (id) ON DELETE CASCADE,
  source_entry_key text NOT NULL CHECK (btrim(source_entry_key) <> ''),
  club_name text NOT NULL CHECK (btrim(club_name) <> ''),
  sort_order integer NOT NULL CHECK (sort_order >= 0),
  raw_entry jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(raw_entry) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (transfermarkt_profile_id, source_entry_key)
);

CREATE INDEX player_youth_history_profile_order_idx
  ON player_youth_history (transfermarkt_profile_id, sort_order);

CREATE TABLE player_injury_history (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfermarkt_profile_id bigint NOT NULL REFERENCES transfermarkt_profiles (id) ON DELETE CASCADE,
  source_entry_key text NOT NULL CHECK (btrim(source_entry_key) <> ''),
  injury_name text NOT NULL CHECK (btrim(injury_name) <> ''),
  started_on date,
  ended_on date,
  days_absent integer CHECK (days_absent IS NULL OR days_absent >= 0),
  is_current boolean NOT NULL DEFAULT false,
  raw_entry jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(raw_entry) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (ended_on IS NULL OR started_on IS NULL OR ended_on >= started_on),
  UNIQUE (transfermarkt_profile_id, source_entry_key)
);

CREATE UNIQUE INDEX player_injury_history_one_current_injury
  ON player_injury_history (transfermarkt_profile_id)
  WHERE is_current;

CREATE TABLE transfer_reports (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  dedupe_key text NOT NULL UNIQUE CHECK (btrim(dedupe_key) <> ''),
  player_id bigint REFERENCES players (id) ON DELETE RESTRICT,
  reported_player_name text NOT NULL CHECK (btrim(reported_player_name) <> ''),
  current_club_name text,
  destination_club_name text,
  classification text NOT NULL CHECK (classification IN (
    'official_confirmed',
    'advanced_negotiations',
    'rumor',
    'rejected_failed',
    'contract_renewal',
    'loan'
  )),
  move_type text NOT NULL DEFAULT 'unknown'
    CHECK (move_type IN ('permanent', 'loan', 'unknown')),
  fee_amount numeric(14,2) CHECK (fee_amount IS NULL OR fee_amount >= 0),
  fee_currency char(3) CHECK (fee_currency IS NULL OR fee_currency ~ '^[A-Z]{3}$'),
  add_ons_amount numeric(14,2) CHECK (add_ons_amount IS NULL OR add_ons_amount >= 0),
  add_ons_currency char(3)
    CHECK (add_ons_currency IS NULL OR add_ons_currency ~ '^[A-Z]{3}$'),
  release_clause_amount numeric(14,2)
    CHECK (release_clause_amount IS NULL OR release_clause_amount >= 0),
  release_clause_currency char(3)
    CHECK (release_clause_currency IS NULL OR release_clause_currency ~ '^[A-Z]{3}$'),
  contract_length_months integer CHECK (contract_length_months IS NULL OR contract_length_months > 0),
  contract_expires_on date,
  loan_ends_on date,
  has_option_to_buy boolean,
  has_obligation_to_buy boolean,
  sell_on_percentage numeric(5,2)
    CHECK (sell_on_percentage IS NULL OR sell_on_percentage BETWEEN 0 AND 100),
  medical_status text,
  agreement_status text,
  confidence numeric(4,3) NOT NULL CHECK (confidence BETWEEN 0 AND 1),
  first_reported_at timestamptz NOT NULL,
  last_reported_at timestamptz NOT NULL,
  normalized_data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(normalized_data) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (last_reported_at >= first_reported_at)
);

CREATE INDEX transfer_reports_player_latest_idx
  ON transfer_reports (player_id, last_reported_at DESC);
CREATE INDEX transfer_reports_classification_latest_idx
  ON transfer_reports (classification, last_reported_at DESC);

CREATE TABLE transfer_report_sources (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfer_report_id bigint NOT NULL REFERENCES transfer_reports (id) ON DELETE CASCADE,
  raw_post_id bigint NOT NULL REFERENCES raw_posts (id) ON DELETE RESTRICT,
  source_observed_at timestamptz NOT NULL,
  extracted_data jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(extracted_data) = 'object'),
  is_preferred boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (transfer_report_id, raw_post_id)
);

CREATE UNIQUE INDEX transfer_report_sources_one_preferred_source
  ON transfer_report_sources (transfer_report_id)
  WHERE is_preferred;
CREATE INDEX transfer_report_sources_raw_post_idx
  ON transfer_report_sources (raw_post_id);

CREATE TABLE transfer_report_revisions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfer_report_id bigint NOT NULL REFERENCES transfer_reports (id) ON DELETE CASCADE,
  revision_number integer NOT NULL CHECK (revision_number > 0),
  content_sha256 text NOT NULL CHECK (content_sha256 ~ '^[a-f0-9]{64}$'),
  snapshot jsonb NOT NULL CHECK (jsonb_typeof(snapshot) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (transfer_report_id, revision_number),
  UNIQUE (transfer_report_id, content_sha256)
);

CREATE TABLE workflow_runs (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workflow_name text NOT NULL CHECK (btrim(workflow_name) <> ''),
  external_execution_id text NOT NULL CHECK (btrim(external_execution_id) <> ''),
  logical_run_key text NOT NULL CHECK (btrim(logical_run_key) <> ''),
  attempt_number integer NOT NULL DEFAULT 1 CHECK (attempt_number > 0),
  status text NOT NULL CHECK (status IN ('running', 'succeeded', 'failed', 'cancelled')),
  started_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  finished_at timestamptz,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(metadata) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (finished_at IS NULL OR finished_at >= started_at),
  UNIQUE (workflow_name, external_execution_id),
  UNIQUE (workflow_name, logical_run_key, attempt_number)
);

CREATE INDEX workflow_runs_status_started_idx
  ON workflow_runs (status, started_at DESC);

CREATE TABLE failures (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workflow_run_id bigint REFERENCES workflow_runs (id) ON DELETE SET NULL,
  operation_name text NOT NULL CHECK (btrim(operation_name) <> ''),
  error_fingerprint text NOT NULL CHECK (btrim(error_fingerprint) <> ''),
  error_class text,
  error_message text NOT NULL CHECK (btrim(error_message) <> ''),
  details jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(details) = 'object'),
  occurrences integer NOT NULL DEFAULT 1 CHECK (occurrences > 0),
  first_seen_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  last_seen_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  resolved_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (last_seen_at >= first_seen_at),
  CHECK (resolved_at IS NULL OR resolved_at >= first_seen_at),
  UNIQUE NULLS NOT DISTINCT (workflow_run_id, operation_name, error_fingerprint)
);

CREATE INDEX failures_unresolved_last_seen_idx
  ON failures (last_seen_at DESC)
  WHERE resolved_at IS NULL;

CREATE TABLE retry_states (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  resource_type text NOT NULL CHECK (resource_type IN (
    'raw_post',
    'transfer_report',
    'digest_delivery',
    'transfermarkt_profile'
  )),
  resource_key text NOT NULL CHECK (btrim(resource_key) <> ''),
  operation_name text NOT NULL CHECK (btrim(operation_name) <> ''),
  state text NOT NULL DEFAULT 'ready' CHECK (state IN (
    'ready',
    'leased',
    'succeeded',
    'retrying',
    'failed',
    'dead_letter',
    'unknown'
  )),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  next_attempt_at timestamptz,
  lease_token text,
  lease_expires_at timestamptz,
  last_failure_id bigint REFERENCES failures (id) ON DELETE SET NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (lease_expires_at IS NULL OR lease_token IS NOT NULL),
  UNIQUE (resource_type, resource_key, operation_name)
);

CREATE INDEX retry_states_ready_next_attempt_idx
  ON retry_states (next_attempt_at)
  WHERE state IN ('ready', 'retrying');

CREATE TABLE digest_deliveries (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  idempotency_key text NOT NULL UNIQUE CHECK (btrim(idempotency_key) <> ''),
  channel_key text NOT NULL CHECK (btrim(channel_key) <> ''),
  window_started_at timestamptz NOT NULL,
  window_ended_at timestamptz NOT NULL,
  status text NOT NULL DEFAULT 'pending'
    CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'unknown', 'cancelled')),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
  discord_message_id text,
  response_payload jsonb NOT NULL DEFAULT '{}'::jsonb CHECK (jsonb_typeof(response_payload) = 'object'),
  first_attempted_at timestamptz,
  last_attempted_at timestamptz,
  sent_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  CHECK (window_ended_at > window_started_at),
  CHECK (last_attempted_at IS NULL OR first_attempted_at IS NULL OR last_attempted_at >= first_attempted_at),
  CHECK (status <> 'sent' OR sent_at IS NOT NULL),
  UNIQUE (channel_key, window_started_at, window_ended_at)
);

CREATE INDEX digest_deliveries_status_created_idx
  ON digest_deliveries (status, created_at);

CREATE TABLE digest_items (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  digest_delivery_id bigint NOT NULL REFERENCES digest_deliveries (id) ON DELETE CASCADE,
  transfer_report_revision_id bigint NOT NULL REFERENCES transfer_report_revisions (id) ON DELETE RESTRICT,
  position smallint NOT NULL CHECK (position BETWEEN 1 AND 18),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (digest_delivery_id, position),
  UNIQUE (digest_delivery_id, transfer_report_revision_id),
  UNIQUE (transfer_report_revision_id)
);

CREATE TRIGGER source_accounts_set_updated_at
  BEFORE UPDATE ON source_accounts
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER raw_posts_set_updated_at
  BEFORE UPDATE ON raw_posts
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER players_set_updated_at
  BEFORE UPDATE ON players
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER transfermarkt_profiles_set_updated_at
  BEFORE UPDATE ON transfermarkt_profiles
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER player_transfer_history_set_updated_at
  BEFORE UPDATE ON player_transfer_history
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER player_youth_history_set_updated_at
  BEFORE UPDATE ON player_youth_history
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER player_injury_history_set_updated_at
  BEFORE UPDATE ON player_injury_history
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER transfer_reports_set_updated_at
  BEFORE UPDATE ON transfer_reports
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER transfer_report_sources_set_updated_at
  BEFORE UPDATE ON transfer_report_sources
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER workflow_runs_set_updated_at
  BEFORE UPDATE ON workflow_runs
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER failures_set_updated_at
  BEFORE UPDATE ON failures
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER retry_states_set_updated_at
  BEFORE UPDATE ON retry_states
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
CREATE TRIGGER digest_deliveries_set_updated_at
  BEFORE UPDATE ON digest_deliveries
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();

COMMIT;
