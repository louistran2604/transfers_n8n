ALTER TABLE source_accounts
  ADD COLUMN seed_reliability numeric(5,4)
    CHECK (seed_reliability IS NULL OR seed_reliability BETWEEN 0 AND 1),
  ADD COLUMN publisher_group_key text
    CHECK (publisher_group_key IS NULL OR btrim(publisher_group_key) <> ''),
  ADD COLUMN source_kind text CHECK (source_kind IS NULL OR source_kind IN (
    'journalist', 'publisher', 'club_official', 'league_official', 'aggregator'
  )),
  ADD COLUMN is_aggregator boolean NOT NULL DEFAULT false;

CREATE TABLE transfer_cases (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  case_key text NOT NULL UNIQUE CHECK (btrim(case_key) <> ''),
  player_id bigint REFERENCES players (id) ON DELETE RESTRICT,
  normalized_current_club text
    CHECK (normalized_current_club IS NULL OR btrim(normalized_current_club) <> ''),
  transfer_window_key text NOT NULL CHECK (btrim(transfer_window_key) <> ''),
  status text NOT NULL DEFAULT 'open'
    CHECK (status IN ('open', 'completed', 'collapsed', 'closed')),
  stay_probability numeric(6,5)
    CHECK (stay_probability IS NULL OR stay_probability BETWEEN 0 AND 1),
  probability_engine_version text
    CHECK (probability_engine_version IS NULL OR btrim(probability_engine_version) <> ''),
  version_counter bigint NOT NULL DEFAULT 0 CHECK (version_counter >= 0),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

ALTER TABLE transfer_reports
  ADD COLUMN transfer_case_id bigint
    REFERENCES transfer_cases (id) ON DELETE SET NULL,
  ADD COLUMN transfer_stage text CHECK (transfer_stage IS NULL OR transfer_stage IN (
    'link', 'interest', 'talks', 'advanced', 'agreed', 'done', 'collapsed'
  )),
  ADD COLUMN raw_probability numeric(6,5)
    CHECK (raw_probability IS NULL OR raw_probability BETWEEN 0 AND 1),
  ADD COLUMN normalized_probability numeric(6,5)
    CHECK (normalized_probability IS NULL OR normalized_probability BETWEEN 0 AND 1),
  ADD COLUMN probability_engine_version text
    CHECK (probability_engine_version IS NULL OR btrim(probability_engine_version) <> ''),
  ADD COLUMN probability_explanation jsonb
    CHECK (
      probability_explanation IS NULL
      OR jsonb_typeof(probability_explanation) = 'object'
    ),
  ADD COLUMN probability_updated_at timestamptz;

CREATE INDEX transfer_reports_case_idx
  ON transfer_reports (transfer_case_id);

CREATE TABLE transfer_evidence (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfer_report_id bigint REFERENCES transfer_reports (id) ON DELETE SET NULL,
  transfer_case_id bigint REFERENCES transfer_cases (id) ON DELETE SET NULL,
  raw_post_id bigint NOT NULL REFERENCES raw_posts (id) ON DELETE RESTRICT,
  extraction_schema_version text NOT NULL
    CHECK (btrim(extraction_schema_version) <> ''),
  report_ordinal integer NOT NULL CHECK (report_ordinal > 0),
  destination_club_name text
    CHECK (destination_club_name IS NULL OR btrim(destination_club_name) <> ''),
  stage_signal text NOT NULL CHECK (stage_signal IN (
    'link', 'interest', 'talks', 'advanced', 'agreed', 'done',
    'setback', 'collapsed', 'official_wording', 'not_reported'
  )),
  claim_stance text NOT NULL CHECK (claim_stance IN (
    'supports', 'contradicts', 'neutral'
  )),
  wording_strength text NOT NULL CHECK (wording_strength IN (
    'hedged', 'reported', 'direct', 'definitive'
  )),
  club_agreement_state text NOT NULL CHECK (club_agreement_state IN (
    'not_reported', 'not_applicable', 'talks', 'agreed', 'rejected', 'collapsed'
  )),
  personal_terms_state text NOT NULL CHECK (personal_terms_state IN (
    'not_reported', 'talks', 'agreed', 'rejected'
  )),
  completion_claim text NOT NULL CHECK (completion_claim IN (
    'none', 'reporter_done', 'official_announcement'
  )),
  attribution_kind text NOT NULL CHECK (attribution_kind IN (
    'original', 'cites_named_source', 'aggregation', 'unknown'
  )),
  named_originator text
    CHECK (named_originator IS NULL OR btrim(named_originator) <> ''),
  resolved_independence_key text
    CHECK (
      resolved_independence_key IS NULL
      OR btrim(resolved_independence_key) <> ''
    ),
  extraction_confidence numeric(5,4) NOT NULL
    CHECK (extraction_confidence BETWEEN 0 AND 1),
  raw_normalized_extraction jsonb NOT NULL
    CHECK (jsonb_typeof(raw_normalized_extraction) = 'object'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (raw_post_id, report_ordinal, extraction_schema_version)
);

CREATE INDEX transfer_evidence_case_idx
  ON transfer_evidence (transfer_case_id, created_at);

CREATE TABLE transfer_probability_revisions (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  transfer_report_id bigint NOT NULL
    REFERENCES transfer_reports (id) ON DELETE CASCADE,
  transfer_case_id bigint NOT NULL REFERENCES transfer_cases (id) ON DELETE CASCADE,
  revision_number integer NOT NULL CHECK (revision_number > 0),
  engine_version text NOT NULL CHECK (btrim(engine_version) <> ''),
  evaluated_at timestamptz NOT NULL,
  raw_probability numeric(6,5) NOT NULL CHECK (raw_probability BETWEEN 0 AND 1),
  normalized_probability numeric(6,5) NOT NULL
    CHECK (normalized_probability BETWEEN 0 AND 1),
  previous_probability numeric(6,5)
    CHECK (previous_probability IS NULL OR previous_probability BETWEEN 0 AND 1),
  probability_delta numeric(6,5)
    CHECK (probability_delta IS NULL OR probability_delta BETWEEN -1 AND 1),
  current_stage text NOT NULL CHECK (current_stage IN (
    'link', 'interest', 'talks', 'advanced', 'agreed', 'done', 'collapsed'
  )),
  explanation jsonb NOT NULL CHECK (jsonb_typeof(explanation) = 'object'),
  input_fingerprint text NOT NULL CHECK (input_fingerprint ~ '^[a-f0-9]{64}$'),
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (transfer_report_id, revision_number),
  UNIQUE (transfer_report_id, input_fingerprint, engine_version)
);

CREATE INDEX transfer_probability_revisions_case_idx
  ON transfer_probability_revisions (transfer_case_id, evaluated_at DESC);

CREATE TABLE source_reliability_snapshots (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_account_id bigint NOT NULL
    REFERENCES source_accounts (id) ON DELETE RESTRICT,
  engine_version text NOT NULL CHECK (btrim(engine_version) <> ''),
  alpha numeric(12,4) NOT NULL CHECK (alpha > 0),
  beta numeric(12,4) NOT NULL CHECK (beta > 0),
  effective_resolved_count numeric(12,4) NOT NULL
    CHECK (effective_resolved_count >= 0),
  posterior_reliability numeric(5,4) NOT NULL
    CHECK (posterior_reliability BETWEEN 0 AND 1),
  calculated_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (source_account_id, engine_version, calculated_at)
);

CREATE TABLE source_claim_outcomes (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  source_account_id bigint NOT NULL
    REFERENCES source_accounts (id) ON DELETE RESTRICT,
  transfer_case_id bigint NOT NULL REFERENCES transfer_cases (id) ON DELETE RESTRICT,
  transfer_report_id bigint NOT NULL
    REFERENCES transfer_reports (id) ON DELETE RESTRICT,
  first_eligible_stage text NOT NULL CHECK (first_eligible_stage IN (
    'advanced', 'agreed', 'done'
  )),
  claimed_at timestamptz NOT NULL,
  settlement_outcome text
    CHECK (settlement_outcome IS NULL OR settlement_outcome IN ('success', 'failure')),
  outcome_weight numeric(5,4) NOT NULL CHECK (outcome_weight > 0 AND outcome_weight <= 1),
  authoritative_raw_post_id bigint REFERENCES raw_posts (id) ON DELETE RESTRICT,
  authoritative_transfer_report_revision_id bigint
    REFERENCES transfer_report_revisions (id) ON DELETE RESTRICT,
  settled_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  UNIQUE (source_account_id, transfer_case_id, transfer_report_id),
  CHECK (
    (
      settlement_outcome IS NULL
      AND authoritative_raw_post_id IS NULL
      AND authoritative_transfer_report_revision_id IS NULL
      AND settled_at IS NULL
    )
    OR (
      settlement_outcome IS NOT NULL
      AND settled_at IS NOT NULL
      AND (
        authoritative_raw_post_id IS NOT NULL
        OR authoritative_transfer_report_revision_id IS NOT NULL
      )
    )
  )
);

CREATE TRIGGER transfer_cases_set_updated_at
  BEFORE UPDATE ON transfer_cases
  FOR EACH ROW EXECUTE FUNCTION app_set_updated_at();
