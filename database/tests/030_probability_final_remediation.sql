\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 996000000000000000;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES
  ('996000000000000001', 'remedreporter', 'Remediation Reporter', 'individual', 2,
    0.850, 0.850, 'reporter:remediation', 'journalist'),
  ('996000000000000002', 'remedclub', 'Remediation Club', 'organization', 1,
    1.000, 1.000, 'club:remediation', 'club_official');
SELECT id AS reporter_id FROM source_accounts WHERE username = 'remedreporter' \gset
SELECT id AS official_id FROM source_accounts WHERE username = 'remedclub' \gset

CREATE FUNCTION pg_temp.make_report(label text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint; report_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('remediation-' || label, 'Remediation ' || label, 'remediation ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('remediation-' || label || '|old-fc|2026-H2', player_id, 'old fc', '2026-H2')
  RETURNING id INTO case_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name,
    destination_club_name, classification, confidence, first_reported_at,
    last_reported_at, transfer_case_id
  ) VALUES ('remediation-' || label, player_id, 'Remediation ' || label,
    'Old FC', 'New FC', 'rumor', 0.8, '2026-08-01', '2026-08-01', case_id)
  RETURNING id INTO report_id;
  INSERT INTO transfer_report_revisions (
    transfer_report_id, revision_number, content_sha256, snapshot
  ) VALUES (report_id, 1,
    encode(sha256(convert_to('remediation-' || report_id, 'UTF8')), 'hex'),
    jsonb_build_object('player_name', 'Remediation ' || label,
      'current_club_name', 'Old FC', 'destination_club_name', 'New FC',
      'classification', 'rumor', 'move_type', 'permanent', 'confidence', 0.8,
      'is_digest_worthy', true));
  RETURN report_id;
END;
$$;

CREATE FUNCTION pg_temp.apply_evidence(
  report_id bigint, source_id bigint, posted_at timestamptz, evaluated_at timestamptz,
  stage text, stance text DEFAULT 'supports', club_state text DEFAULT 'talks',
  personal_state text DEFAULT 'talks', completion text DEFAULT 'none'
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE raw_id bigint; destination text; result_id bigint;
BEGIN
  SELECT destination_club_name INTO destination FROM transfer_reports WHERE id = report_id;
  INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
  VALUES (source_id, nextval('pg_temp.fixture_id')::text,
    'https://x.com/remediation/status/' || currval('pg_temp.fixture_id'),
    'final remediation fixture', posted_at) RETURNING id INTO raw_id;
  SELECT apply_probability_v1_active(report_id, jsonb_build_object(
    'probability_mode', 'active', 'evaluated_at', evaluated_at,
    'destination_club_name', destination,
    'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
    'sources', jsonb_build_array(jsonb_build_object(
      'raw_post_id', raw_id, 'posted_at', posted_at, 'report_ordinal', 1,
      'extraction_schema_version', 'qwen-evidence-v1',
      'normalized_evidence', jsonb_build_object(
        'stage_signal', stage, 'claim_stance', stance, 'wording_strength', 'direct',
        'club_agreement_state', club_state, 'personal_terms_state', personal_state,
        'completion_claim', completion, 'attribution_kind', 'original',
        'named_originator', NULL, 'extraction_confidence', 0.95))
  ))) INTO result_id;
  RETURN result_id;
END;
$$;

CREATE FUNCTION pg_temp.replay_latest(report_id bigint, evaluated_at timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE evidence_row transfer_evidence%ROWTYPE; post_row raw_posts%ROWTYPE;
  destination text; result_id bigint;
BEGIN
  SELECT * INTO evidence_row FROM transfer_evidence
  WHERE transfer_report_id = report_id ORDER BY id DESC LIMIT 1;
  SELECT * INTO post_row FROM raw_posts WHERE id = evidence_row.raw_post_id;
  SELECT destination_club_name INTO destination FROM transfer_reports WHERE id = report_id;
  SELECT apply_probability_v1_active(report_id, jsonb_build_object(
    'probability_mode', 'active', 'evaluated_at', evaluated_at,
    'destination_club_name', destination,
    'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
    'sources', jsonb_build_array(jsonb_build_object(
      'raw_post_id', evidence_row.raw_post_id, 'posted_at', post_row.posted_at,
      'report_ordinal', evidence_row.report_ordinal,
      'extraction_schema_version', evidence_row.extraction_schema_version,
      'normalized_evidence', evidence_row.raw_normalized_extraction - '_resolved_source'
    ))
  )) INTO result_id;
  RETURN result_id;
END;
$$;

-- Superseded advanced evidence cannot reopen an authoritative collapse.
SELECT pg_temp.make_report('superseded-denial') AS denial_report \gset
SELECT pg_temp.apply_evidence(:denial_report, :official_id,
  '2026-08-01 09:00+00', '2026-08-01 10:00+00', 'collapsed',
  club_state => 'collapsed');
SELECT pg_temp.apply_evidence(:denial_report, :reporter_id,
  '2026-08-02 09:00+00', '2026-08-02 10:00+00', 'advanced');
SELECT pg_temp.apply_evidence(:denial_report, :reporter_id,
  '2026-08-03 09:00+00', '2026-08-03 10:00+00', 'not_reported', 'contradicts');
SELECT pg_temp.assert_true('superseded advanced evidence reopened after denial',
  (SELECT transfer_stage = 'collapsed' FROM transfer_reports WHERE id = :denial_report));

SELECT pg_temp.make_report('superseded-lower') AS lower_report \gset
SELECT pg_temp.apply_evidence(:lower_report, :official_id,
  '2026-08-01 09:00+00', '2026-08-01 10:00+00', 'collapsed',
  club_state => 'collapsed');
SELECT pg_temp.apply_evidence(:lower_report, :reporter_id,
  '2026-08-02 09:00+00', '2026-08-02 10:00+00', 'advanced');
SELECT pg_temp.apply_evidence(:lower_report, :reporter_id,
  '2026-08-03 09:00+00', '2026-08-03 10:00+00', 'talks');
SELECT pg_temp.assert_true('superseded advanced evidence reopened after lower support',
  (SELECT transfer_stage = 'collapsed' FROM transfer_reports WHERE id = :lower_report));

SELECT pg_temp.make_report('current-advanced') AS current_report \gset
SELECT pg_temp.apply_evidence(:current_report, :official_id,
  '2026-08-01 09:00+00', '2026-08-01 10:00+00', 'collapsed',
  club_state => 'collapsed');
SELECT pg_temp.apply_evidence(:current_report, :reporter_id,
  '2026-08-02 09:00+00', '2026-08-02 10:00+00', 'advanced');
SELECT pg_temp.assert_true('current advanced evidence did not reopen',
  (SELECT transfer_stage = 'advanced' FROM transfer_reports WHERE id = :current_report));

-- Contradiction-only scoring must change revision/fingerprint with time and posterior.
SELECT pg_temp.make_report('reliability') AS reliability_report \gset
SELECT pg_temp.apply_evidence(:reliability_report, :reporter_id,
  '2026-08-01 09:00+00', '2026-08-01 10:00+00', 'not_reported', 'contradicts');
SELECT input_fingerprint AS first_fingerprint, normalized_probability AS first_probability,
  revision_number AS first_revision
FROM transfer_probability_revisions WHERE transfer_report_id = :reliability_report
ORDER BY revision_number DESC LIMIT 1 \gset

SELECT pg_temp.replay_latest(:reliability_report, '2026-08-08 10:00+00');
SELECT input_fingerprint AS decayed_fingerprint, normalized_probability AS decayed_probability,
  revision_number AS decayed_revision
FROM transfer_probability_revisions WHERE transfer_report_id = :reliability_report
ORDER BY revision_number DESC LIMIT 1 \gset
SELECT pg_temp.assert_true('later decay did not create a new contradiction revision',
  :'decayed_fingerprint' <> :'first_fingerprint'
  AND :decayed_revision > :first_revision
  AND :'decayed_probability'::numeric <> :'first_probability'::numeric);

INSERT INTO source_reliability_snapshots (
  source_account_id, engine_version, alpha, beta, effective_resolved_count,
  posterior_reliability, calculated_at
) VALUES (:reporter_id, 'probability-v1', 5.5, 4.5, 2, 0.55, '2026-08-09 09:00+00');
SELECT pg_temp.replay_latest(:reliability_report, '2026-08-09 10:00+00');
SELECT input_fingerprint AS posterior_fingerprint,
  normalized_probability AS posterior_probability, revision_number AS posterior_revision,
  (explanation #>> '{contradictions,0,reliability}')::numeric AS posterior_used
FROM transfer_probability_revisions WHERE transfer_report_id = :reliability_report
ORDER BY revision_number DESC LIMIT 1 \gset
SELECT pg_temp.assert_true('eligible posterior did not change contradiction scoring',
  :'posterior_fingerprint' <> :'decayed_fingerprint'
  AND :posterior_revision > :decayed_revision
  AND :'posterior_probability'::numeric <> :'decayed_probability'::numeric
  AND :'posterior_used'::numeric = 0.55);

SELECT pg_temp.replay_latest(:reliability_report, '2026-08-09 10:00+00');
SELECT pg_temp.assert_true('same-time replay changed the posterior fingerprint',
  (SELECT count(*) FROM transfer_probability_revisions
    WHERE transfer_report_id = :reliability_report) = :posterior_revision);

ROLLBACK;

SELECT 'probability final remediation tests passed' AS result;
