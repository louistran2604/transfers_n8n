\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF (
    SELECT count(*)
    FROM app_schema_migrations
    WHERE version = '003_transfer_probability'
  ) <> 1 THEN
    RAISE EXCEPTION 'Migration 003_transfer_probability has not been applied exactly once';
  END IF;
END;
$$;

-- Old writers name only pre-003 columns.
INSERT INTO source_accounts (
  external_account_id,
  username,
  display_name,
  account_type,
  priority_rank,
  reliability_score
)
VALUES (
  '900000000000000501',
  'probabilitytest',
  'Probability Test Source',
  'individual',
  5,
  0.875
)
RETURNING id \gset source_

INSERT INTO raw_posts (
  source_account_id,
  external_post_id,
  post_url,
  content,
  posted_at
)
VALUES (
  :source_id,
  '900000000000000502',
  'https://x.com/probabilitytest/status/900000000000000502',
  'Probability schema contract fixture.',
  '2026-08-27 00:00:00+00'
)
RETURNING id \gset raw_post_

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('probability-player', 'Probability Player', 'probability player')
RETURNING id \gset player_

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
  'probability-player|old-fc|new-fc',
  :player_id,
  'Probability Player',
  'Old FC',
  'New FC',
  'rumor',
  0.750,
  '2026-08-27 00:00:00+00',
  '2026-08-27 00:00:00+00'
)
RETURNING id \gset report_

INSERT INTO transfer_cases (
  case_key,
  player_id,
  normalized_current_club,
  transfer_window_key
)
VALUES (
  'probability-player|old-fc|2026-summer',
  :player_id,
  'old fc',
  '2026-summer'
)
RETURNING id \gset transfer_case_

INSERT INTO transfer_cases (case_key, transfer_window_key)
VALUES ('probability-player|old-fc|2026-summer', '2026-summer')
ON CONFLICT (case_key) DO NOTHING;

UPDATE transfer_cases
SET version_counter = version_counter + 1
WHERE id = :transfer_case_id
RETURNING version_counter \gset case_lock_

UPDATE transfer_reports
SET transfer_case_id = :transfer_case_id
WHERE id = :report_id;

INSERT INTO transfer_evidence (
  transfer_report_id,
  transfer_case_id,
  raw_post_id,
  extraction_schema_version,
  report_ordinal,
  destination_club_name,
  stage_signal,
  claim_stance,
  wording_strength,
  club_agreement_state,
  personal_terms_state,
  completion_claim,
  attribution_kind,
  named_originator,
  resolved_independence_key,
  extraction_confidence,
  raw_normalized_extraction
)
VALUES (
  :report_id,
  :transfer_case_id,
  :raw_post_id,
  'evidence-v1',
  1,
  'New FC',
  'advanced',
  'supports',
  'direct',
  'talks',
  'agreed',
  'none',
  'original',
  NULL,
  'source:' || :source_id,
  0.9500,
  '{"stage_signal":"advanced"}'::jsonb
)
ON CONFLICT (raw_post_id, report_ordinal, extraction_schema_version) DO NOTHING
RETURNING id \gset evidence_

INSERT INTO transfer_evidence (
  transfer_report_id,
  transfer_case_id,
  raw_post_id,
  extraction_schema_version,
  report_ordinal,
  stage_signal,
  claim_stance,
  wording_strength,
  club_agreement_state,
  personal_terms_state,
  completion_claim,
  attribution_kind,
  extraction_confidence,
  raw_normalized_extraction
)
VALUES (
  :report_id,
  :transfer_case_id,
  :raw_post_id,
  'evidence-v1',
  1,
  'link',
  'neutral',
  'hedged',
  'not_reported',
  'not_reported',
  'none',
  'unknown',
  0.5000,
  '{}'::jsonb
)
ON CONFLICT (raw_post_id, report_ordinal, extraction_schema_version) DO NOTHING;

INSERT INTO transfer_probability_revisions (
  transfer_report_id,
  transfer_case_id,
  revision_number,
  engine_version,
  evaluated_at,
  raw_probability,
  normalized_probability,
  previous_probability,
  probability_delta,
  current_stage,
  explanation,
  input_fingerprint
)
VALUES (
  :report_id,
  :transfer_case_id,
  1,
  'probability-v1',
  '2026-08-27 00:01:00+00',
  0.65000,
  0.60000,
  NULL,
  NULL,
  'advanced',
  '{"engine_version":"probability-v1"}'::jsonb,
  repeat('a', 64)
)
RETURNING id \gset probability_revision_

INSERT INTO transfer_probability_revisions (
  transfer_report_id, transfer_case_id, revision_number, engine_version,
  evaluated_at, raw_probability, normalized_probability, current_stage,
  explanation, input_fingerprint
)
VALUES (
  :report_id, :transfer_case_id, 1, 'probability-v1',
  '2026-08-27 00:02:00+00', 0.66000, 0.61000, 'advanced',
  '{}'::jsonb, repeat('b', 64)
)
ON CONFLICT (transfer_report_id, revision_number) DO NOTHING;

INSERT INTO transfer_probability_revisions (
  transfer_report_id, transfer_case_id, revision_number, engine_version,
  evaluated_at, raw_probability, normalized_probability, current_stage,
  explanation, input_fingerprint
)
VALUES (
  :report_id, :transfer_case_id, 2, 'probability-v1',
  '2026-08-27 00:03:00+00', 0.66000, 0.61000, 'advanced',
  '{}'::jsonb, repeat('a', 64)
)
ON CONFLICT (transfer_report_id, input_fingerprint, engine_version) DO NOTHING;

INSERT INTO source_reliability_snapshots (
  source_account_id,
  engine_version,
  alpha,
  beta,
  effective_resolved_count,
  posterior_reliability,
  calculated_at
)
VALUES (
  :source_id,
  'probability-v1',
  8.5,
  1.5,
  2.0,
  0.8500,
  '2026-08-27 00:04:00+00'
);

INSERT INTO source_reliability_snapshots (
  source_account_id,
  engine_version,
  alpha,
  beta,
  effective_resolved_count,
  posterior_reliability,
  calculated_at
)
VALUES (
  :source_id,
  'probability-v1',
  8.5,
  1.5,
  2.0,
  0.8500,
  '2026-08-27 00:04:00+00'
)
ON CONFLICT (source_account_id, engine_version, calculated_at) DO NOTHING;

INSERT INTO source_claim_outcomes (
  source_account_id,
  transfer_case_id,
  transfer_report_id,
  first_eligible_stage,
  claimed_at,
  settlement_outcome,
  outcome_weight,
  authoritative_raw_post_id,
  settled_at
)
VALUES (
  :source_id,
  :transfer_case_id,
  :report_id,
  'advanced',
  '2026-08-27 00:00:00+00',
  'success',
  0.5000,
  :raw_post_id,
  '2026-08-27 00:05:00+00'
);

INSERT INTO source_claim_outcomes (
  source_account_id,
  transfer_case_id,
  transfer_report_id,
  first_eligible_stage,
  claimed_at,
  outcome_weight
)
VALUES (
  :source_id,
  :transfer_case_id,
  :report_id,
  'advanced',
  '2026-08-27 00:00:00+00',
  0.5000
)
ON CONFLICT (source_account_id, transfer_case_id, transfer_report_id) DO NOTHING;

DO $$
BEGIN
  INSERT INTO source_accounts (
    external_account_id, username, display_name, account_type, priority_rank,
    seed_reliability
  ) VALUES (
    '900000000000000503', 'badreliability', 'Bad Reliability', 'individual', 9,
    1.0001
  );
  RAISE EXCEPTION 'invalid seed reliability was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
DECLARE
  enum_column text;
BEGIN
  FOREACH enum_column IN ARRAY ARRAY[
    'claim_stance',
    'wording_strength',
    'club_agreement_state',
    'personal_terms_state',
    'completion_claim',
    'attribution_kind'
  ] LOOP
    BEGIN
      EXECUTE format(
        'UPDATE transfer_evidence SET %I = ''invalid'' WHERE id = $1',
        enum_column
      ) USING (
        SELECT id
        FROM transfer_evidence
        WHERE extraction_schema_version = 'evidence-v1'
      );
      RAISE EXCEPTION 'invalid value was accepted for %', enum_column;
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;
  END LOOP;
END;
$$;

DO $$
BEGIN
  UPDATE source_accounts
  SET source_kind = 'blog'
  WHERE external_account_id = '900000000000000501';
  RAISE EXCEPTION 'invalid source kind was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
BEGIN
  UPDATE transfer_reports
  SET normalized_probability = 1.00001
  WHERE dedupe_key = 'probability-player|old-fc|new-fc';
  RAISE EXCEPTION 'invalid report probability was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
BEGIN
  UPDATE transfer_reports
  SET transfer_stage = 'medical'
  WHERE dedupe_key = 'probability-player|old-fc|new-fc';
  RAISE EXCEPTION 'invalid transfer stage was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
BEGIN
  INSERT INTO transfer_evidence (
    raw_post_id, extraction_schema_version, report_ordinal, stage_signal,
    claim_stance, wording_strength, club_agreement_state,
    personal_terms_state, completion_claim, attribution_kind,
    extraction_confidence, raw_normalized_extraction
  ) VALUES (
    (SELECT id FROM raw_posts WHERE external_post_id = '900000000000000502'),
    'bad-evidence-v1', 1, 'medical',
    'supports', 'direct', 'talks', 'agreed', 'none', 'original',
    0.9000, '{}'::jsonb
  );
  RAISE EXCEPTION 'invalid evidence stage was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
BEGIN
  INSERT INTO transfer_probability_revisions (
    transfer_report_id, transfer_case_id, revision_number, engine_version,
    evaluated_at, raw_probability, normalized_probability, current_stage,
    explanation, input_fingerprint
  ) VALUES (
    (
      SELECT id FROM transfer_reports
      WHERE dedupe_key = 'probability-player|old-fc|new-fc'
    ),
    (
      SELECT id FROM transfer_cases
      WHERE case_key = 'probability-player|old-fc|2026-summer'
    ),
    2, 'probability-v2', CURRENT_TIMESTAMP,
    -0.00001, 0.50000, 'link', '{}'::jsonb, repeat('c', 64)
  );
  RAISE EXCEPTION 'invalid revision probability was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
BEGIN
  INSERT INTO source_reliability_snapshots (
    source_account_id, engine_version, alpha, beta, effective_resolved_count,
    posterior_reliability, calculated_at
  ) VALUES (
    (
      SELECT id FROM source_accounts
      WHERE external_account_id = '900000000000000501'
    ),
    'probability-v1', 0, 1, 0, 0.5000, CURRENT_TIMESTAMP
  );
  RAISE EXCEPTION 'nonpositive reliability alpha was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
DECLARE
  invalid_source_id bigint;
BEGIN
  INSERT INTO source_accounts (
    external_account_id, username, display_name, account_type, priority_rank
  ) VALUES (
    '900000000000000504', 'invalidoutcome', 'Invalid Outcome', 'individual', 10
  )
  RETURNING id INTO invalid_source_id;

  INSERT INTO source_claim_outcomes (
    source_account_id, transfer_case_id, transfer_report_id,
    first_eligible_stage, claimed_at, settlement_outcome, outcome_weight,
    settled_at
  ) VALUES (
    invalid_source_id,
    (
      SELECT id FROM transfer_cases
      WHERE case_key = 'probability-player|old-fc|2026-summer'
    ),
    (
      SELECT id FROM transfer_reports
      WHERE dedupe_key = 'probability-player|old-fc|new-fc'
    ),
    'advanced', CURRENT_TIMESTAMP,
    'failure', 0.5000, CURRENT_TIMESTAMP
  );
  RAISE EXCEPTION 'settled outcome without authoritative evidence was accepted';
EXCEPTION WHEN check_violation THEN
  NULL;
END;
$$;

DO $$
BEGIN
  IF NOT (
    (
      SELECT version_counter = 1
      FROM transfer_cases
      WHERE case_key = 'probability-player|old-fc|2026-summer'
    )
   AND (
     SELECT count(*) FROM transfer_cases
     WHERE case_key = 'probability-player|old-fc|2026-summer'
   ) = 1
   AND (
     SELECT count(*) FROM transfer_evidence
     WHERE raw_post_id = (
       SELECT id FROM raw_posts WHERE external_post_id = '900000000000000502'
     )
       AND report_ordinal = 1
       AND extraction_schema_version = 'evidence-v1'
   ) = 1
   AND (
     SELECT count(*) FROM transfer_probability_revisions
     WHERE transfer_report_id = (
       SELECT id FROM transfer_reports
       WHERE dedupe_key = 'probability-player|old-fc|new-fc'
     )
   ) = 1
   AND (
     SELECT count(*) FROM source_claim_outcomes
     WHERE source_account_id = (
       SELECT id FROM source_accounts
       WHERE external_account_id = '900000000000000501'
     )
       AND transfer_case_id = (
         SELECT id FROM transfer_cases
         WHERE case_key = 'probability-player|old-fc|2026-summer'
       )
       AND transfer_report_id = (
         SELECT id FROM transfer_reports
         WHERE dedupe_key = 'probability-player|old-fc|new-fc'
       )
       AND authoritative_raw_post_id = (
         SELECT id FROM raw_posts
         WHERE external_post_id = '900000000000000502'
       )
   ) = 1
   AND (
     SELECT count(*)
     FROM source_reliability_snapshots
     WHERE source_account_id = (
       SELECT id FROM source_accounts
       WHERE external_account_id = '900000000000000501'
     )
       AND engine_version = 'probability-v1'
       AND calculated_at = '2026-08-27 00:04:00+00'
   ) = 1
   AND (
     SELECT confidence = 0.750
       AND raw_probability IS NULL
       AND normalized_probability IS NULL
       AND probability_engine_version IS NULL
     FROM transfer_reports
     WHERE dedupe_key = 'probability-player|old-fc|new-fc'
   )
   AND (
     SELECT NOT is_aggregator
       AND seed_reliability IS NULL
       AND publisher_group_key IS NULL
       AND source_kind IS NULL
     FROM source_accounts
     WHERE external_account_id = '900000000000000501'
   )
  ) THEN
    RAISE EXCEPTION 'Transfer probability schema contract failed';
  END IF;
END;
$$;

ROLLBACK;
