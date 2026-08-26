\set ON_ERROR_STOP on

BEGIN;

DO $$
BEGIN
  IF (SELECT count(*) FROM app_schema_migrations WHERE version = '004_probability_v1_engine') <> 1 THEN
    RAISE EXCEPTION 'Migration 004_probability_v1_engine has not been applied exactly once';
  END IF;
END;
$$;

CREATE FUNCTION pg_temp.assert_close(label text, actual numeric, expected numeric, tolerance numeric DEFAULT 0.00001)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF actual IS NULL OR abs(actual - expected) > tolerance THEN
    RAISE EXCEPTION '%: expected %, got %', label, expected, actual;
  END IF;
END;
$$;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION '%', label;
  END IF;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 910000000000000000;

CREATE FUNCTION pg_temp.make_report(label text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  player_id bigint;
  case_id bigint;
  report_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('p-v1-' || label, 'Player ' || label, 'player ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('p-v1-' || label || '|old-fc|2026-H2', player_id, 'old fc', '2026-H2')
  RETURNING id INTO case_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
    classification, confidence, first_reported_at, last_reported_at, transfer_case_id
  ) VALUES (
    'p-v1-' || label || '|old-fc|new-fc', player_id, 'Player ' || label, 'Old FC', 'New FC',
    'rumor', 0.8, '2026-08-01 00:00:00+00', '2026-08-27 00:00:00+00', case_id
  ) RETURNING id INTO report_id;
  RETURN report_id;
END;
$$;

CREATE FUNCTION pg_temp.add_evidence(
  report_id bigint,
  source_id bigint,
  posted_at timestamptz,
  stage_signal text DEFAULT 'advanced',
  claim_stance text DEFAULT 'supports',
  wording_strength text DEFAULT 'direct',
  club_state text DEFAULT 'talks',
  personal_state text DEFAULT 'talks',
  completion_claim text DEFAULT 'none',
  attribution_kind text DEFAULT 'original',
  named_originator text DEFAULT NULL,
  independence_key text DEFAULT NULL,
  extraction_confidence numeric DEFAULT 0.95
)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  post_id bigint;
  evidence_id bigint;
  external_id text := nextval('pg_temp.fixture_id')::text;
BEGIN
  INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
  VALUES (source_id, external_id, 'https://x.com/test/status/' || external_id, 'probability-v1 fixture', posted_at)
  RETURNING id INTO post_id;
  INSERT INTO transfer_evidence (
    transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version, report_ordinal,
    destination_club_name, stage_signal, claim_stance, wording_strength, club_agreement_state,
    personal_terms_state, completion_claim, attribution_kind, named_originator,
    resolved_independence_key, extraction_confidence, raw_normalized_extraction
  ) SELECT
    report_id, transfer_case_id, post_id, 'qwen-evidence-v1', 1,
    destination_club_name, $4, $5, $6, $7,
    $8, $9, $10, $11,
    COALESCE($12, 'source:' || source_id), $13,
    jsonb_build_object('stage_signal', $4, 'claim_stance', $5)
  FROM transfer_reports WHERE id = report_id
  RETURNING id INTO evidence_id;
  RETURN evidence_id;
END;
$$;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES
  ('910000000000000101', 'v1primary', 'V1 Primary', 'individual', 2, 0.850, 0.850, 'reporter:v1primary', 'journalist'),
  ('910000000000000102', 'v1samegroup', 'V1 Same Group', 'individual', 3, 0.900, 0.900, 'reporter:v1primary', 'journalist'),
  ('910000000000000103', 'v1independent', 'V1 Independent', 'individual', 3, 0.800, 0.800, 'reporter:v1independent', 'journalist'),
  ('910000000000000104', 'v1low', 'V1 Low', 'individual', 4, 0.600, 0.600, 'reporter:v1low', 'journalist'),
  ('910000000000000105', 'v1high', 'V1 High', 'individual', 2, 0.950, 0.950, 'reporter:v1high', 'journalist'),
  ('910000000000000106', 'v1official', 'V1 Official', 'organization', 1, 1.000, 1.000, 'club:v1-official', 'club_official'),
  ('910000000000000107', 'v1snapshot', 'V1 Snapshot', 'individual', 3, 0.650, 0.650, 'reporter:v1snapshot', 'journalist');

SELECT id AS primary_id FROM source_accounts WHERE username = 'v1primary' \gset
SELECT id AS same_id FROM source_accounts WHERE username = 'v1samegroup' \gset
SELECT id AS independent_id FROM source_accounts WHERE username = 'v1independent' \gset
SELECT id AS low_id FROM source_accounts WHERE username = 'v1low' \gset
SELECT id AS high_id FROM source_accounts WHERE username = 'v1high' \gset
SELECT id AS official_id FROM source_accounts WHERE username = 'v1official' \gset
SELECT id AS snapshot_id FROM source_accounts WHERE username = 'v1snapshot' \gset

SELECT pg_temp.assert_close('posterior prior weight 8', probability_v1_reporter_posterior(0.75, 2, 0.5), 0.7619047619, 0.000000001);
SELECT pg_temp.assert_close('posterior lower clamp', probability_v1_reporter_posterior(0, 0, 100), 0.55);
SELECT pg_temp.assert_close('posterior upper clamp', probability_v1_reporter_posterior(1, 100, 0), 0.95);

INSERT INTO source_reliability_snapshots (
  source_account_id, engine_version, alpha, beta, effective_resolved_count,
  posterior_reliability, calculated_at
) VALUES
  (:snapshot_id, 'probability-v1', 8, 2, 2, 0.8000, '2026-08-26 00:00:00+00'),
  (:snapshot_id, 'probability-v1', 9, 1, 2, 0.9000, '2026-08-28 00:00:00+00');
SELECT pg_temp.make_report('snapshot') AS snapshot_report \gset
SELECT pg_temp.add_evidence(:snapshot_report, :snapshot_id, '2026-08-27 00:00:00+00');
SELECT pg_temp.assert_close('latest applicable reliability snapshot',
  (SELECT explanation #>> '{primary,reliability}' FROM score_transfer_probability_v1(:snapshot_report, '2026-08-27 00:00:00+00'))::numeric,
  0.80);

SELECT pg_temp.make_report('golden') AS golden_report \gset
SELECT pg_temp.add_evidence(:golden_report, :primary_id, '2026-08-27 00:00:00+00');
SELECT pg_temp.assert_close('advanced golden raw', raw_probability, 0.59885)
FROM score_transfer_probability_v1(:golden_report, '2026-08-27 00:00:00+00');

SELECT pg_temp.make_report('perm-a') AS perm_a \gset
SELECT pg_temp.make_report('perm-b') AS perm_b \gset
SELECT pg_temp.add_evidence(:perm_a, :primary_id, '2026-08-27 00:00:00+00', independence_key => 'reporter:v1primary');
SELECT pg_temp.add_evidence(:perm_a, :independent_id, '2026-08-27 00:01:00+00', wording_strength => 'reported', independence_key => 'reporter:v1independent');
SELECT pg_temp.add_evidence(:perm_b, :independent_id, '2026-08-27 00:01:00+00', wording_strength => 'reported', independence_key => 'reporter:v1independent');
SELECT pg_temp.add_evidence(:perm_b, :primary_id, '2026-08-27 00:00:00+00', independence_key => 'reporter:v1primary');
SELECT pg_temp.assert_close('input permutation invariance',
  (SELECT raw_probability FROM score_transfer_probability_v1(:perm_a, '2026-08-27 00:02:00+00')),
  (SELECT raw_probability FROM score_transfer_probability_v1(:perm_b, '2026-08-27 00:02:00+00')));

SELECT pg_temp.make_report('single') AS single_report \gset
SELECT pg_temp.make_report('repeat') AS repeat_report \gset
SELECT pg_temp.make_report('independent') AS independent_report \gset
SELECT pg_temp.add_evidence(:single_report, :primary_id, '2026-08-27 00:00:00+00', independence_key => 'reporter:v1primary');
SELECT pg_temp.add_evidence(:repeat_report, :same_id, '2026-08-26 00:00:00+00', stage_signal => 'talks', independence_key => 'reporter:v1primary');
SELECT pg_temp.add_evidence(:repeat_report, :primary_id, '2026-08-27 00:00:00+00', independence_key => 'reporter:v1primary');
SELECT pg_temp.add_evidence(:independent_report, :primary_id, '2026-08-27 00:00:00+00', independence_key => 'reporter:v1primary');
SELECT pg_temp.add_evidence(:independent_report, :independent_id, '2026-08-27 00:00:00+00', independence_key => 'reporter:v1independent');
SELECT pg_temp.assert_close('same group repetition has no boost',
  (SELECT raw_probability FROM score_transfer_probability_v1(:single_report, '2026-08-27 00:00:00+00')),
  (SELECT raw_probability FROM score_transfer_probability_v1(:repeat_report, '2026-08-27 00:00:00+00')));
SELECT pg_temp.assert_true('independent group did not raise probability',
  (SELECT raw_probability FROM score_transfer_probability_v1(:independent_report, '2026-08-27 00:00:00+00'))
  > (SELECT raw_probability FROM score_transfer_probability_v1(:single_report, '2026-08-27 00:00:00+00')));

SELECT pg_temp.make_report('low-r') AS low_report \gset
SELECT pg_temp.make_report('high-r') AS high_report \gset
SELECT pg_temp.add_evidence(:low_report, :low_id, '2026-08-27 00:00:00+00');
SELECT pg_temp.add_evidence(:high_report, :high_id, '2026-08-27 00:00:00+00');
SELECT pg_temp.assert_true('higher reliability did not increase primary adjustment',
  (SELECT explanation #>> '{primary,adjustment}' FROM score_transfer_probability_v1(:high_report, '2026-08-27 00:00:00+00'))::numeric
  > (SELECT explanation #>> '{primary,adjustment}' FROM score_transfer_probability_v1(:low_report, '2026-08-27 00:00:00+00'))::numeric);

SELECT pg_temp.make_report('fresh') AS fresh_report \gset
SELECT pg_temp.make_report('stale') AS stale_report \gset
SELECT pg_temp.add_evidence(:fresh_report, :primary_id, '2026-08-27 00:00:00+00');
SELECT pg_temp.add_evidence(:stale_report, :primary_id, '2026-08-07 00:00:00+00');
SELECT pg_temp.assert_true('fresh evidence did not outweigh stale evidence',
  (SELECT raw_probability FROM score_transfer_probability_v1(:fresh_report, '2026-08-27 00:00:00+00'))
  > (SELECT raw_probability FROM score_transfer_probability_v1(:stale_report, '2026-08-27 00:00:00+00')));

SELECT pg_temp.make_report('one-gate') AS one_gate_report \gset
SELECT pg_temp.make_report('both-gates') AS both_gates_report \gset
SELECT pg_temp.add_evidence(:one_gate_report, :primary_id, '2026-08-27', stage_signal => 'agreed', club_state => 'agreed', personal_state => 'not_reported');
SELECT pg_temp.add_evidence(:both_gates_report, :primary_id, '2026-08-27', stage_signal => 'agreed', club_state => 'not_applicable', personal_state => 'agreed');
SELECT pg_temp.assert_true('agreed gate anchors are wrong',
  (SELECT explanation #>> '{stage,base}' FROM score_transfer_probability_v1(:one_gate_report, '2026-08-27'))::numeric = 0.72
  AND (SELECT explanation #>> '{stage,ceiling}' FROM score_transfer_probability_v1(:one_gate_report, '2026-08-27'))::numeric = 0.90
  AND (SELECT explanation #>> '{stage,base}' FROM score_transfer_probability_v1(:both_gates_report, '2026-08-27'))::numeric = 0.90
  AND (SELECT explanation #>> '{stage,ceiling}' FROM score_transfer_probability_v1(:both_gates_report, '2026-08-27'))::numeric = 0.97);

SELECT pg_temp.make_report('contradictions') AS contradiction_report \gset
SELECT pg_temp.add_evidence(:contradiction_report, :primary_id, '2026-08-27', independence_key => 'reporter:v1primary');
SELECT pg_temp.add_evidence(:contradiction_report, :independent_id, '2026-08-27', stage_signal => 'advanced', claim_stance => 'contradicts', club_state => 'rejected', independence_key => 'reject');
SELECT pg_temp.add_evidence(:contradiction_report, :low_id, '2026-08-27', stage_signal => 'setback', claim_stance => 'contradicts', independence_key => 'setback');
SELECT pg_temp.add_evidence(:contradiction_report, :same_id, '2026-08-27', stage_signal => 'advanced', claim_stance => 'contradicts', independence_key => 'direct-denial');
SELECT pg_temp.add_evidence(:contradiction_report, :high_id, '2026-08-27', stage_signal => 'collapsed', claim_stance => 'contradicts', club_state => 'collapsed', independence_key => 'denial');
SELECT pg_temp.assert_true('non-authoritative contradictions were treated as terminal/supporting',
  (SELECT current_stage FROM score_transfer_probability_v1(:contradiction_report, '2026-08-27')) <> 'collapsed'
  AND (SELECT raw_probability FROM score_transfer_probability_v1(:contradiction_report, '2026-08-27'))
    < (SELECT raw_probability FROM score_transfer_probability_v1(:single_report, '2026-08-27')));
SELECT pg_temp.assert_true('contradiction bases are wrong',
  (SELECT explanation->'contradictions' FROM score_transfer_probability_v1(:contradiction_report, '2026-08-27'))
    @> '[{"base": -0.8}, {"base": -0.6}, {"base": -1.6}]'::jsonb);
SELECT pg_temp.assert_true('direct denial and non-authoritative collapse did not both use -1.60',
  (SELECT count(*) FROM score_transfer_probability_v1(:contradiction_report, '2026-08-27') scored,
    jsonb_array_elements(scored.explanation->'contradictions') item
    WHERE (item->>'base')::numeric = -1.60) = 2);

SELECT pg_temp.make_report('reporter-done') AS reporter_done_report \gset
SELECT pg_temp.make_report('wording-done') AS wording_done_report \gset
SELECT pg_temp.make_report('official-done') AS official_done_report \gset
SELECT pg_temp.make_report('official-collapse') AS official_collapse_report \gset
SELECT pg_temp.add_evidence(:reporter_done_report, :primary_id, '2026-08-27', stage_signal => 'done', completion_claim => 'reporter_done');
SELECT pg_temp.add_evidence(:wording_done_report, :primary_id, '2026-08-27', stage_signal => 'official_wording', completion_claim => 'official_announcement');
SELECT pg_temp.add_evidence(:official_done_report, :official_id, '2026-08-27', stage_signal => 'official_wording', completion_claim => 'official_announcement');
SELECT pg_temp.add_evidence(:official_collapse_report, :official_id, '2026-08-27', stage_signal => 'collapsed', claim_stance => 'contradicts', club_state => 'collapsed');
SELECT pg_temp.assert_true('reporter done exceeded ceiling',
  (SELECT raw_probability FROM score_transfer_probability_v1(:reporter_done_report, '2026-08-27')) <= 0.98);
SELECT pg_temp.assert_true('non-authoritative official wording became terminal',
  (SELECT raw_probability FROM score_transfer_probability_v1(:wording_done_report, '2026-08-27')) < 1);
SELECT pg_temp.assert_true('official confirmation was not 1.0',
  (SELECT raw_probability FROM score_transfer_probability_v1(:official_done_report, '2026-08-27')) = 1);
SELECT pg_temp.assert_true('official collapse was not 0.02',
  (SELECT raw_probability FROM score_transfer_probability_v1(:official_collapse_report, '2026-08-27')) = 0.02);

SELECT pg_temp.make_report('low-confidence') AS low_conf_report \gset
SELECT pg_temp.add_evidence(:low_conf_report, :primary_id, '2026-08-27', stage_signal => 'link', extraction_confidence => 0.9);
SELECT pg_temp.add_evidence(:low_conf_report, :official_id, '2026-08-27', stage_signal => 'official_wording', completion_claim => 'official_announcement', extraction_confidence => 0.49);
SELECT pg_temp.assert_true('low-confidence evidence was not stored',
  (SELECT count(*) FROM transfer_evidence WHERE transfer_report_id = :low_conf_report) = 2);
SELECT pg_temp.assert_true('low-confidence evidence affected scoring',
  (SELECT current_stage FROM score_transfer_probability_v1(:low_conf_report, '2026-08-27')) = 'link');

SELECT pg_temp.assert_close('explanation total',
  (explanation->>'base_logit')::numeric + (explanation->>'total_adjustment')::numeric,
  (explanation->>'unclamped_logit')::numeric, 0.0000001)
FROM score_transfer_probability_v1(:golden_report, '2026-08-27');
SELECT pg_temp.assert_close('explanation probability',
  LEAST((explanation #>> '{stage,ceiling}')::numeric, (explanation->>'unclamped_probability')::numeric),
  raw_probability, 0.00001)
FROM score_transfer_probability_v1(:golden_report, '2026-08-27');
SELECT pg_temp.assert_true('probability/fingerprint bounds failed', raw_probability BETWEEN 0 AND 1
  AND input_fingerprint ~ '^[a-f0-9]{64}$')
FROM score_transfer_probability_v1(:golden_report, '2026-08-27');

INSERT INTO transfer_evidence (
  transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version, report_ordinal,
  destination_club_name, stage_signal, claim_stance, wording_strength, club_agreement_state,
  personal_terms_state, completion_claim, attribution_kind, named_originator,
  resolved_independence_key, extraction_confidence, raw_normalized_extraction
)
SELECT transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version, report_ordinal,
  destination_club_name, stage_signal, claim_stance, wording_strength, club_agreement_state,
  personal_terms_state, completion_claim, attribution_kind, named_originator,
  resolved_independence_key, extraction_confidence, raw_normalized_extraction
FROM transfer_evidence WHERE transfer_report_id = :golden_report
ON CONFLICT (raw_post_id, report_ordinal, extraction_schema_version) DO NOTHING;
SELECT pg_temp.assert_true('evidence replay was not idempotent',
  (SELECT count(*) FROM transfer_evidence WHERE transfer_report_id = :golden_report) = 1);

CREATE FUNCTION pg_temp.shadow_payload(report_id bigint)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'probability_mode', 'shadow',
    'evaluated_at', '2026-08-27T00:00:00Z',
    'destination_club_name', report.destination_club_name,
    'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
    'sources', jsonb_agg(jsonb_build_object(
      'raw_post_id', evidence.raw_post_id,
      'posted_at', post.posted_at,
      'report_ordinal', evidence.report_ordinal,
      'extraction_schema_version', evidence.extraction_schema_version,
      'normalized_evidence', evidence.raw_normalized_extraction || jsonb_build_object(
        'wording_strength', evidence.wording_strength,
        'club_agreement_state', evidence.club_agreement_state,
        'personal_terms_state', evidence.personal_terms_state,
        'completion_claim', evidence.completion_claim,
        'attribution_kind', evidence.attribution_kind,
        'named_originator', evidence.named_originator,
        'extraction_confidence', evidence.extraction_confidence
      )
    ))
  )
  FROM transfer_reports report
  JOIN transfer_evidence evidence ON evidence.transfer_report_id = report.id
  JOIN raw_posts post ON post.id = evidence.raw_post_id
  WHERE report.id = report_id
  GROUP BY report.destination_club_name;
$$;

SELECT apply_probability_v1_shadow(:golden_report, pg_temp.shadow_payload(:golden_report));
SELECT apply_probability_v1_shadow(:golden_report, pg_temp.shadow_payload(:golden_report));

SELECT pg_temp.assert_true('revision replay was not idempotent',
  (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :golden_report) = 1);
SELECT pg_temp.assert_true('shadow apply did not update report columns',
  (SELECT raw_probability = normalized_probability
      AND probability_engine_version = 'probability-v1'
      AND probability_explanation->>'normalization' = 'pending-stage-5'
    FROM transfer_reports WHERE id = :golden_report));

ROLLBACK;

SELECT 'probability-v1 engine tests passed' AS result;
