\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 995000000000000000;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES
  ('995000000000000001', 'reviewreporter', 'Review Reporter', 'individual', 2,
    0.850, 0.850, 'reporter:review', 'journalist'),
  ('995000000000000002', 'reviewclub', 'Review Club', 'organization', 1,
    1.000, 1.000, 'club:review', 'club_official');
SELECT id AS reporter_id FROM source_accounts WHERE username = 'reviewreporter' \gset
SELECT id AS official_id FROM source_accounts WHERE username = 'reviewclub' \gset

CREATE FUNCTION pg_temp.make_report(label text, destination text DEFAULT 'Review FC')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint; report_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('review-' || label, 'Review ' || label, 'review ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('review-' || label || '|old-fc|2026-H2', player_id, 'old fc', '2026-H2')
  RETURNING id INTO case_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name,
    destination_club_name, classification, confidence, first_reported_at,
    last_reported_at, transfer_case_id
  ) VALUES (
    'review-' || label || '|old-fc|' || lower(replace(destination, ' ', '-')),
    player_id, 'Review ' || label, 'Old FC', destination, 'rumor', 0.8,
    '2026-08-01', '2026-08-01', case_id
  ) RETURNING id INTO report_id;
  INSERT INTO transfer_report_revisions (
    transfer_report_id, revision_number, content_sha256, snapshot
  ) VALUES (
    report_id, 1,
    encode(sha256(convert_to('review-core-' || report_id, 'UTF8')), 'hex'),
    jsonb_build_object(
      'player_name', 'Review ' || label,
      'current_club_name', 'Old FC',
      'destination_club_name', destination,
      'classification', 'rumor',
      'move_type', 'permanent',
      'confidence', 0.8,
      'is_digest_worthy', true
    )
  );
  RETURN report_id;
END;
$$;

CREATE FUNCTION pg_temp.apply_evidence(
  requested_report_id bigint,
  requested_source_id bigint,
  requested_posted_at timestamptz,
  requested_evaluated_at timestamptz,
  requested_stage text,
  requested_stance text DEFAULT 'supports',
  requested_club_state text DEFAULT 'talks',
  requested_personal_state text DEFAULT 'talks',
  requested_completion text DEFAULT 'none'
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE raw_id bigint; destination text; case_key text; result_id bigint;
BEGIN
  SELECT destination_club_name INTO destination
  FROM transfer_reports WHERE id = requested_report_id;
  INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
  VALUES (requested_source_id, nextval('pg_temp.fixture_id')::text,
    'https://x.com/review/status/' || currval('pg_temp.fixture_id'),
    'probability final review fixture', requested_posted_at)
  RETURNING id INTO raw_id;
  SELECT apply_probability_v1_active(
    requested_report_id,
    jsonb_build_object(
      'probability_mode', 'active',
      'evaluated_at', requested_evaluated_at,
      'destination_club_name', destination,
      'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
      'sources', jsonb_build_array(jsonb_build_object(
        'raw_post_id', raw_id,
        'posted_at', requested_posted_at,
        'report_ordinal', (SELECT count(*) + 1 FROM raw_posts WHERE id = raw_id),
        'extraction_schema_version', 'qwen-evidence-v1',
        'normalized_evidence', jsonb_build_object(
          'stage_signal', requested_stage,
          'claim_stance', requested_stance,
          'wording_strength', 'direct',
          'club_agreement_state', requested_club_state,
          'personal_terms_state', requested_personal_state,
          'completion_claim', requested_completion,
          'attribution_kind', 'original',
          'named_originator', NULL,
          'extraction_confidence', 0.95
        )
      ))
    )
  ) INTO result_id;
  RETURN result_id;
END;
$$;

-- A collapse is terminal through equal-time advanced and later talks evidence,
-- but strictly later advanced support reopens through the real active apply path.
SELECT pg_temp.make_report('reopen') AS reopen_report \gset
SELECT pg_temp.apply_evidence(:reopen_report, :reporter_id,
  '2026-08-01 10:00+00', '2026-08-01 11:00+00', 'advanced');
SELECT pg_temp.apply_evidence(:reopen_report, :official_id,
  '2026-08-02 10:00+00', '2026-08-02 11:00+00', 'collapsed',
  'supports', 'collapsed', 'talks');
SELECT count(*) AS collapse_revisions
FROM transfer_probability_revisions WHERE transfer_report_id = :reopen_report \gset
SELECT pg_temp.assert_true('authoritative collapse did not become terminal',
  (SELECT transfer_stage = 'collapsed'
      AND probability_explanation->>'terminal_kind' = 'authoritative_collapse'
    FROM transfer_reports WHERE id = :reopen_report)
  AND (SELECT status = 'collapsed'
    FROM transfer_cases WHERE id = (SELECT transfer_case_id FROM transfer_reports WHERE id = :reopen_report)));
SELECT pg_temp.apply_evidence(:reopen_report, :reporter_id,
  '2026-08-02 10:00+00', '2026-08-02 12:00+00', 'advanced');
SELECT pg_temp.assert_true('equal-time advanced evidence reopened collapse',
  (SELECT transfer_stage = 'collapsed'
      AND probability_explanation->>'terminal_kind' = 'authoritative_collapse'
    FROM transfer_reports WHERE id = :reopen_report));
SELECT pg_temp.apply_evidence(:reopen_report, :reporter_id,
  '2026-08-03 10:00+00', '2026-08-03 11:00+00', 'talks');
SELECT pg_temp.assert_true('later talks evidence reopened collapse',
  (SELECT transfer_stage = 'collapsed'
      AND probability_explanation->>'terminal_kind' = 'authoritative_collapse'
    FROM transfer_reports WHERE id = :reopen_report));
SELECT pg_temp.apply_evidence(:reopen_report, :reporter_id,
  '2026-08-04 10:00+00', '2026-08-04 11:00+00', 'advanced');
SELECT pg_temp.assert_true('strictly later advanced evidence did not reopen collapse',
  (SELECT transfer_stage = 'advanced'
      AND probability_explanation->>'terminal_kind' IS NULL
      AND normalized_probability > 0.02
    FROM transfer_reports WHERE id = :reopen_report)
  AND (SELECT status = 'open'
    FROM transfer_cases WHERE id = (SELECT transfer_case_id FROM transfer_reports WHERE id = :reopen_report))
  AND (SELECT count(*) > :collapse_revisions
    FROM transfer_probability_revisions WHERE transfer_report_id = :reopen_report)
  AND (SELECT count(*) > 0
    FROM transfer_report_revisions
    WHERE transfer_report_id = :reopen_report
      AND snapshot->>'probability_status' = 'active_scored'));

-- Contradiction-only evidence always produces a deterministic non-terminal
-- regression, including rejected bids and direct denials; exact replays do not
-- append a second revision.
SELECT pg_temp.make_report('contradiction') AS contradiction_report \gset
SELECT pg_temp.apply_evidence(:contradiction_report, :reporter_id,
  '2026-08-01 10:00+00', '2026-08-01 11:00+00', 'talks');
SELECT report.normalized_probability AS support_probability,
  count(*) AS support_revisions
FROM transfer_reports report
JOIN transfer_probability_revisions revision ON revision.transfer_report_id = report.id
WHERE report.id = :contradiction_report
GROUP BY report.normalized_probability \gset
SELECT pg_temp.apply_evidence(:contradiction_report, :reporter_id,
  '2026-08-02 10:00+00', '2026-08-02 11:00+00', 'setback', 'contradicts');
SELECT report.normalized_probability AS setback_probability,
  transfer_stage AS setback_stage,
  count(*) AS setback_revisions
FROM transfer_reports report
JOIN transfer_probability_revisions revision ON revision.transfer_report_id = report.id
WHERE report.id = :contradiction_report
GROUP BY report.normalized_probability, report.transfer_stage \gset
SELECT pg_temp.assert_true('same-key setback was ignored or did not regress',
  :'setback_probability'::numeric < :'support_probability'::numeric
  AND :'setback_revisions'::integer > :'support_revisions'::integer
  AND :'setback_stage' = 'link');
SELECT pg_temp.apply_evidence(:contradiction_report, :reporter_id,
  '2026-08-03 10:00+00', '2026-08-03 11:00+00', 'setback', 'supports', 'rejected');
SELECT report.normalized_probability AS rejected_probability,
  count(*) AS rejected_revisions
FROM transfer_reports report
JOIN transfer_probability_revisions revision ON revision.transfer_report_id = report.id
WHERE report.id = :contradiction_report
GROUP BY report.normalized_probability \gset
SELECT pg_temp.assert_true('rejected gate did not lower contradiction-only probability',
  :'rejected_probability'::numeric < :'setback_probability'::numeric
  AND :'rejected_revisions'::integer > :'setback_revisions'::integer);
SELECT pg_temp.apply_evidence(:contradiction_report, :reporter_id,
  '2026-08-04 10:00+00', '2026-08-04 11:00+00', 'not_reported', 'contradicts');
SELECT report.normalized_probability AS denial_probability,
  count(*) AS denial_revisions
FROM transfer_reports report
JOIN transfer_probability_revisions revision ON revision.transfer_report_id = report.id
WHERE report.id = :contradiction_report
GROUP BY report.normalized_probability \gset
SELECT pg_temp.assert_true('direct denial did not lower contradiction-only probability',
  :'denial_probability'::numeric < :'rejected_probability'::numeric
  AND :'denial_revisions'::integer > :'rejected_revisions'::integer);
SELECT count(*) AS replay_revisions,
  report.normalized_probability AS replay_probability
FROM transfer_probability_revisions revision
JOIN transfer_reports report ON report.id = revision.transfer_report_id
WHERE revision.transfer_report_id = :contradiction_report
GROUP BY report.normalized_probability \gset
SELECT post.id AS denial_raw_id
FROM raw_posts post
JOIN transfer_evidence evidence ON evidence.raw_post_id = post.id
WHERE evidence.transfer_report_id = :contradiction_report
  AND post.posted_at = '2026-08-04 10:00+00'
ORDER BY post.id DESC LIMIT 1 \gset
SELECT apply_probability_v1_active(
  :contradiction_report,
  jsonb_build_object(
    'probability_mode', 'active',
    'evaluated_at', '2026-08-04 11:00+00',
    'destination_club_name', (SELECT destination_club_name FROM transfer_reports WHERE id = :contradiction_report),
    'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
    'sources', jsonb_build_array(jsonb_build_object(
      'raw_post_id', :denial_raw_id,
      'posted_at', '2026-08-04 10:00+00',
      'report_ordinal', (SELECT report_ordinal FROM transfer_evidence WHERE raw_post_id = :denial_raw_id),
      'extraction_schema_version', 'qwen-evidence-v1',
      'normalized_evidence', jsonb_build_object(
        'stage_signal', 'not_reported', 'claim_stance', 'contradicts',
        'wording_strength', 'direct', 'club_agreement_state', 'talks',
        'personal_terms_state', 'talks', 'completion_claim', 'none',
        'attribution_kind', 'original', 'named_originator', NULL,
        'extraction_confidence', 0.95
      )
    ))
  )
);
SELECT pg_temp.assert_true('same-time denial replay was not fingerprint-idempotent',
  (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :contradiction_report) = :replay_revisions
  AND (SELECT normalized_probability FROM transfer_reports WHERE id = :contradiction_report) = :'replay_probability'::numeric);

-- One entry-point call drains every eligible case in repeated bounded chunks.
DO $$
DECLARE i integer; player_id bigint; case_id bigint; report_id bigint;
  fixture_source_id bigint;
BEGIN
  SELECT id INTO fixture_source_id FROM source_accounts WHERE username = 'reviewreporter';
  FOR i IN 1..201 LOOP
    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES ('review-drain-' || i, 'Review Drain ' || i, 'review drain ' || i)
    RETURNING id INTO player_id;
    INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
    VALUES ('review-drain-' || i || '|old-fc|2026-H1', player_id, 'old fc', '2026-H1')
    RETURNING id INTO case_id;
    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name,
      destination_club_name, classification, confidence,
      first_reported_at, last_reported_at, transfer_case_id
    ) VALUES (
      'review-drain-' || i, player_id, 'Review Drain ' || i, 'Old FC',
      'Drain FC', 'rumor', 0.8, '2026-01-01', '2026-01-01', case_id
    ) RETURNING id INTO report_id;
    INSERT INTO source_claim_outcomes (
      source_account_id, transfer_case_id, transfer_report_id,
      first_eligible_stage, claimed_at, outcome_weight
    ) VALUES (fixture_source_id, case_id, report_id, 'advanced', '2026-01-01', 0.5);
  END LOOP;
END;
$$;
SELECT settle_expired_probability_v1_cases(
  'shadow', '2026-07-15 00:00+00', 100) AS drained_count \gset
SELECT pg_temp.assert_true('one settlement call stranded eligible cases',
  :drained_count = 201
  AND (SELECT count(*) = 201 FROM source_claim_outcomes outcome
    WHERE outcome.transfer_case_id IN (
      SELECT id FROM transfer_cases WHERE case_key LIKE 'review-drain-%'))
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes outcome
    WHERE outcome.transfer_case_id IN (
      SELECT id FROM transfer_cases WHERE case_key LIKE 'review-drain-%')
      AND outcome.settlement_outcome IS NULL));
SELECT settle_expired_probability_v1_cases(
  'shadow', '2026-07-15 00:00+00', 100) AS replay_count \gset
SELECT pg_temp.assert_true('settlement replay was not idempotent', :replay_count = 0);

ROLLBACK;

SELECT 'probability final review tests passed' AS result;
