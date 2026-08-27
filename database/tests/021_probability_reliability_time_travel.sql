\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END;
$$;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('992000000000000001', 'timetravelrep', 'Time Travel Reporter', 'individual', 1,
  0.750, 0.750, 'reporter:time-travel', 'journalist') RETURNING id AS source_id \gset
INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('time-travel-player', 'Time Travel Player', 'time travel player')
RETURNING id AS player_id \gset
INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('time-travel-player|old-fc|2026-H1', :player_id, 'old fc', '2026-H1')
RETURNING id AS case_id \gset
INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name,
  destination_club_name, classification, confidence, first_reported_at,
  last_reported_at, transfer_case_id
) VALUES ('time-travel-player|new-fc', :player_id, 'Time Travel Player', 'Old FC',
  'New FC', 'rumor', 0.8, '2026-05-01', '2026-05-01', :case_id)
RETURNING id AS report_id \gset
INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
VALUES (:source_id, '992000000000000002', 'https://x.com/timetravelrep/status/1',
  'advanced talks', '2026-05-01 00:00+00') RETURNING id AS raw_post_id \gset
INSERT INTO transfer_evidence (
  transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
  report_ordinal, destination_club_name, stage_signal, claim_stance,
  wording_strength, club_agreement_state, personal_terms_state, completion_claim,
  attribution_kind, resolved_independence_key, extraction_confidence,
  raw_normalized_extraction
) VALUES (:report_id, :case_id, :raw_post_id, 'qwen-evidence-v1', 1, 'New FC',
  'advanced', 'supports', 'direct', 'not_reported', 'not_reported', 'none',
  'original', 'reporter:time-travel', 0.95, jsonb_build_object(
    'stage_signal', 'advanced', 'claim_stance', 'supports', 'wording_strength', 'direct',
    'club_agreement_state', 'not_reported', 'personal_terms_state', 'not_reported',
    'completion_claim', 'none', 'attribution_kind', 'original',
    'extraction_confidence', 0.95, '_resolved_source', jsonb_build_object(
      'account_id', :source_id, 'username', 'timetravelrep',
      'source_kind', 'journalist', 'seed_reliability', 0.75)));

INSERT INTO transfer_probability_revisions (
  transfer_report_id, transfer_case_id, revision_number, engine_version,
  evaluated_at, raw_probability, normalized_probability, current_stage,
  explanation, input_fingerprint
) SELECT :report_id, :case_id, 1, 'probability-v1', '2026-05-15 00:00+00',
  raw_probability, raw_probability, current_stage, explanation, input_fingerprint
FROM score_transfer_probability_v1(:report_id, '2026-05-15 00:00+00');
SELECT explanation #>> '{primary,reliability}' AS old_reliability,
  input_fingerprint AS old_fingerprint
FROM transfer_probability_revisions WHERE transfer_report_id = :report_id \gset

INSERT INTO source_reliability_snapshots (
  source_account_id, engine_version, alpha, beta, effective_resolved_count,
  posterior_reliability, calculated_at
) VALUES (:source_id, 'probability-v1', 9, 1, 2, 0.9, '2026-05-16 00:00+00');

SELECT pg_temp.assert_true('snapshot time travel boundary is wrong',
  (SELECT (explanation #>> '{primary,reliability}')::numeric = 0.75
    FROM score_transfer_probability_v1(:report_id, '2026-05-15 23:59:59.999999+00'))
  AND (SELECT (explanation #>> '{primary,reliability}')::numeric = 0.90
    FROM score_transfer_probability_v1(:report_id, '2026-05-16 00:00+00')));
SELECT pg_temp.assert_true('historical probability revision was rewritten after snapshot',
  (SELECT explanation #>> '{primary,reliability}' = :'old_reliability'
      AND input_fingerprint = :'old_fingerprint'
    FROM transfer_probability_revisions WHERE transfer_report_id = :report_id)
  AND (SELECT input_fingerprint = :'old_fingerprint'
    FROM score_transfer_probability_v1(:report_id, '2026-05-15 00:00+00')));

UPDATE transfer_reports SET transfer_stage = 'advanced', raw_probability = 0.5,
  normalized_probability = 0.5, probability_engine_version = 'probability-v1',
  probability_explanation = '{}'::jsonb, probability_updated_at = '2026-05-15 00:00+00',
  probability_status = 'shadow_scored'
WHERE id = :report_id;
SELECT pg_temp.assert_true('off mode recomputed a reporter-affected case',
  recompute_probability_v1_reporter_cases(
    'off', '2026-05-16 00:00+00', NULL, 100) = 0
  AND (SELECT probability_updated_at = '2026-05-15 00:00+00'
    FROM transfer_reports WHERE id = :report_id));
SELECT recompute_probability_v1_reporter_cases(
  'shadow', '2026-05-16 00:00+00', NULL, 100) AS shadow_recomputed \gset
SELECT pg_temp.assert_true('shadow mode did not recompute through the existing apply path',
  :shadow_recomputed = 1
  AND (SELECT probability_updated_at = '2026-05-16 00:00+00'
      AND probability_status = 'shadow_scored'
    FROM transfer_reports WHERE id = :report_id));
INSERT INTO source_reliability_snapshots (
  source_account_id, engine_version, alpha, beta, effective_resolved_count,
  posterior_reliability, calculated_at
) VALUES (:source_id, 'probability-v1', 8.5, 1.5, 3, 0.85, '2026-05-17 00:00+00');
SELECT recompute_probability_v1_reporter_cases(
  'active', '2026-05-17 00:00+00', NULL, 100) AS active_recomputed \gset
SELECT pg_temp.assert_true('active mode did not retain its delivery boundary',
  :active_recomputed = 1
  AND (SELECT probability_updated_at = '2026-05-17 00:00+00'
      AND probability_status = 'active_scored'
    FROM transfer_reports WHERE id = :report_id));

ROLLBACK;
