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

CREATE FUNCTION pg_temp.rejects_with_check_violation(statement text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    EXECUTE statement;
    RAISE EXCEPTION USING ERRCODE = 'PT001';
  EXCEPTION
    WHEN check_violation THEN RETURN true;
    WHEN SQLSTATE 'PT001' THEN RETURN false;
  END;
END;
$$;

CREATE FUNCTION pg_temp.rejects_with_foreign_key_violation(statement text)
RETURNS boolean
LANGUAGE plpgsql
AS $$
BEGIN
  BEGIN
    EXECUTE statement;
    RAISE EXCEPTION USING ERRCODE = 'PT001';
  EXCEPTION
    WHEN foreign_key_violation THEN RETURN true;
    WHEN SQLSTATE 'PT001' THEN RETURN false;
  END;
END;
$$;

CREATE TEMPORARY TABLE expected_rejections (
  label text PRIMARY KEY,
  rejected boolean NOT NULL
) ON COMMIT DROP;

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

INSERT INTO transfer_cases (case_key, transfer_window_key)
VALUES ('probability-player|other-fc|2026-summer', '2026-summer');

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

-- A rollout evidence row may link only the case until its report is available.
INSERT INTO transfer_evidence (
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
  :transfer_case_id,
  :raw_post_id,
  'rollout-v1',
  2,
  'not_reported',
  'neutral',
  'reported',
  'not_reported',
  'not_reported',
  'none',
  'unknown',
  0.5000,
  '{}'::jsonb
);

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
ON CONFLICT DO NOTHING;

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

INSERT INTO expected_rejections (label, rejected)
SELECT label, pg_temp.rejects_with_check_violation(statement)
FROM (VALUES
  ('source seed below zero', $sql$
    UPDATE source_accounts SET seed_reliability = -0.0001
    WHERE external_account_id = '900000000000000501'
  $sql$),
  ('source seed above one', $sql$
    UPDATE source_accounts SET seed_reliability = 1.0001
    WHERE external_account_id = '900000000000000501'
  $sql$),
  ('source kind enum', $sql$
    UPDATE source_accounts SET source_kind = 'invalid'
    WHERE external_account_id = '900000000000000501'
  $sql$),
  ('case stay probability below zero', $sql$
    UPDATE transfer_cases SET stay_probability = -0.00001
    WHERE case_key = 'probability-player|old-fc|2026-summer'
  $sql$),
  ('case stay probability above one', $sql$
    UPDATE transfer_cases SET stay_probability = 1.00001
    WHERE case_key = 'probability-player|old-fc|2026-summer'
  $sql$),
  ('case version counter nonnegative', $sql$
    UPDATE transfer_cases SET version_counter = -1
    WHERE case_key = 'probability-player|old-fc|2026-summer'
  $sql$),
  ('case status enum', $sql$
    UPDATE transfer_cases SET status = 'invalid'
    WHERE case_key = 'probability-player|old-fc|2026-summer'
  $sql$),
  ('report raw probability below zero', $sql$
    UPDATE transfer_reports SET raw_probability = -0.00001
    WHERE dedupe_key = 'probability-player|old-fc|new-fc'
  $sql$),
  ('report raw probability above one', $sql$
    UPDATE transfer_reports SET raw_probability = 1.00001
    WHERE dedupe_key = 'probability-player|old-fc|new-fc'
  $sql$),
  ('report normalized probability below zero', $sql$
    UPDATE transfer_reports SET normalized_probability = -0.00001
    WHERE dedupe_key = 'probability-player|old-fc|new-fc'
  $sql$),
  ('report normalized probability above one', $sql$
    UPDATE transfer_reports SET normalized_probability = 1.00001
    WHERE dedupe_key = 'probability-player|old-fc|new-fc'
  $sql$),
  ('report transfer stage enum', $sql$
    UPDATE transfer_reports SET transfer_stage = 'invalid'
    WHERE dedupe_key = 'probability-player|old-fc|new-fc'
  $sql$),
  ('evidence stage enum', $sql$
    UPDATE transfer_evidence SET stage_signal = 'invalid'
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence stance enum', $sql$
    UPDATE transfer_evidence SET claim_stance = 'invalid'
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence wording enum', $sql$
    UPDATE transfer_evidence SET wording_strength = 'invalid'
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence club agreement enum', $sql$
    UPDATE transfer_evidence SET club_agreement_state = 'invalid'
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence personal terms enum', $sql$
    UPDATE transfer_evidence SET personal_terms_state = 'invalid'
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence completion claim enum', $sql$
    UPDATE transfer_evidence SET completion_claim = 'invalid'
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence attribution enum', $sql$
    UPDATE transfer_evidence SET attribution_kind = 'invalid'
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence confidence below zero', $sql$
    UPDATE transfer_evidence SET extraction_confidence = -0.0001
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('evidence confidence above one', $sql$
    UPDATE transfer_evidence SET extraction_confidence = 1.0001
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('revision raw probability below zero', $sql$
    UPDATE transfer_probability_revisions SET raw_probability = -0.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision raw probability above one', $sql$
    UPDATE transfer_probability_revisions SET raw_probability = 1.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision normalized probability below zero', $sql$
    UPDATE transfer_probability_revisions SET normalized_probability = -0.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision normalized probability above one', $sql$
    UPDATE transfer_probability_revisions SET normalized_probability = 1.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision previous probability below zero', $sql$
    UPDATE transfer_probability_revisions SET previous_probability = -0.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision previous probability above one', $sql$
    UPDATE transfer_probability_revisions SET previous_probability = 1.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision delta below minus one', $sql$
    UPDATE transfer_probability_revisions SET probability_delta = -1.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision delta above one', $sql$
    UPDATE transfer_probability_revisions SET probability_delta = 1.00001
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision current stage enum', $sql$
    UPDATE transfer_probability_revisions SET current_stage = 'invalid'
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('revision number positive', $sql$
    UPDATE transfer_probability_revisions SET revision_number = 0
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('reliability alpha positive', $sql$
    UPDATE source_reliability_snapshots SET alpha = 0
    WHERE engine_version = 'probability-v1'
  $sql$),
  ('reliability beta positive', $sql$
    UPDATE source_reliability_snapshots SET beta = 0
    WHERE engine_version = 'probability-v1'
  $sql$),
  ('reliability effective count nonnegative', $sql$
    UPDATE source_reliability_snapshots SET effective_resolved_count = -0.0001
    WHERE engine_version = 'probability-v1'
  $sql$),
  ('reliability posterior below zero', $sql$
    UPDATE source_reliability_snapshots SET posterior_reliability = -0.0001
    WHERE engine_version = 'probability-v1'
  $sql$),
  ('reliability posterior above one', $sql$
    UPDATE source_reliability_snapshots SET posterior_reliability = 1.0001
    WHERE engine_version = 'probability-v1'
  $sql$),
  ('claim first eligible stage enum', $sql$
    UPDATE source_claim_outcomes SET first_eligible_stage = 'invalid'
    WHERE settlement_outcome = 'success'
  $sql$),
  ('claim settlement outcome enum', $sql$
    UPDATE source_claim_outcomes SET settlement_outcome = 'invalid'
    WHERE settlement_outcome = 'success'
  $sql$),
  ('claim outcome weight positive', $sql$
    UPDATE source_claim_outcomes SET outcome_weight = 0
    WHERE settlement_outcome = 'success'
  $sql$),
  ('claim outcome weight at most one', $sql$
    UPDATE source_claim_outcomes SET outcome_weight = 1.0001
    WHERE settlement_outcome = 'success'
  $sql$),
  ('claim authoritative linkage', $sql$
    UPDATE source_claim_outcomes SET authoritative_raw_post_id = NULL
    WHERE settlement_outcome = 'success'
  $sql$),
  ('claim settled time chronology', $sql$
    UPDATE source_claim_outcomes SET settled_at = claimed_at - INTERVAL '1 second'
    WHERE settlement_outcome = 'success'
  $sql$)
) AS test(label, statement);

INSERT INTO expected_rejections (label, rejected)
SELECT label, pg_temp.rejects_with_foreign_key_violation(statement)
FROM (VALUES
  ('evidence report/case coherence', $sql$
    UPDATE transfer_evidence
    SET transfer_case_id = (
      SELECT id FROM transfer_cases
      WHERE case_key = 'probability-player|other-fc|2026-summer'
    )
    WHERE extraction_schema_version = 'evidence-v1'
  $sql$),
  ('probability revision report/case coherence', $sql$
    UPDATE transfer_probability_revisions
    SET transfer_case_id = (
      SELECT id FROM transfer_cases
      WHERE case_key = 'probability-player|other-fc|2026-summer'
    )
    WHERE input_fingerprint = repeat('a', 64)
  $sql$),
  ('claim outcome report/case coherence', $sql$
    UPDATE source_claim_outcomes
    SET transfer_case_id = (
      SELECT id FROM transfer_cases
      WHERE case_key = 'probability-player|other-fc|2026-summer'
    )
    WHERE settlement_outcome = 'success'
  $sql$)
) AS test(label, statement);

DO $$
DECLARE
  missing_enforcement text;
BEGIN
  SELECT string_agg(label, ', ' ORDER BY label)
  INTO missing_enforcement
  FROM expected_rejections
  WHERE NOT rejected;

  IF missing_enforcement IS NOT NULL THEN
    RAISE EXCEPTION 'Expected rejection was not enforced: %', missing_enforcement;
  END IF;
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
