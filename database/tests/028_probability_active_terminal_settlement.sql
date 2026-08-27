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
  ('996000000000000001', 'terminalrep', 'Terminal Reporter', 'individual', 1,
    0.75, 0.75, 'reporter:terminal', 'journalist'),
  ('996000000000000002', 'terminalfc', 'Terminal FC', 'organization', 1,
    0.90, 0.90, 'official:terminal', 'club_official');
SELECT id AS reporter_id FROM source_accounts WHERE username = 'terminalrep' \gset
SELECT id AS official_id FROM source_accounts WHERE username = 'terminalfc' \gset

CREATE FUNCTION pg_temp.make_report(label text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint; report_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('terminal-' || label, 'Terminal ' || label, 'terminal ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('terminal-' || label || '|old|2026-H2', player_id, 'old', '2026-H2')
  RETURNING id INTO case_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name,
    destination_club_name, classification, confidence, first_reported_at,
    last_reported_at, transfer_case_id
  ) VALUES ('terminal-' || label, player_id, 'Terminal ' || label, 'Old FC',
    'New FC', 'rumor', 0.8, '2026-05-01', '2026-05-01', case_id)
  RETURNING id INTO report_id;
  INSERT INTO transfer_report_revisions (
    transfer_report_id, revision_number, content_sha256, snapshot
  ) VALUES (report_id, 1, encode(sha256(convert_to('terminal-core-' || label, 'UTF8')), 'hex'),
    jsonb_build_object('player_name', 'Terminal ' || label, 'current_club_name', 'Old FC',
      'destination_club_name', 'New FC', 'classification', 'rumor', 'move_type', 'unknown',
      'confidence', 0.8, 'is_digest_worthy', true));
  RETURN report_id;
END;
$$;

CREATE FUNCTION pg_temp.payload(
  report_id bigint, source_id bigint, posted_at timestamptz, evaluated_at timestamptz,
  stage text, completion text DEFAULT 'none', club_state text DEFAULT 'not_reported'
) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE raw_id bigint; username text;
BEGIN
  SELECT source_accounts.username INTO username FROM source_accounts WHERE id = source_id;
  INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
  VALUES (source_id, nextval('pg_temp.fixture_id')::text,
    'https://x.com/' || username || '/status/' || currval('pg_temp.fixture_id'),
    stage, posted_at) RETURNING id INTO raw_id;
  RETURN jsonb_build_object(
    'probability_mode', 'active', 'evaluated_at', evaluated_at,
    'destination_club_name', 'New FC',
    'normalized_data', jsonb_build_object('current_club_key', 'old'),
    'sources', jsonb_build_array(jsonb_build_object(
      'raw_post_id', raw_id, 'posted_at', posted_at, 'report_ordinal', 1,
      'extraction_schema_version', 'qwen-evidence-v1',
      'normalized_evidence', jsonb_build_object(
        'stage_signal', stage, 'claim_stance', 'supports', 'wording_strength', 'direct',
        'club_agreement_state', club_state, 'personal_terms_state', 'not_reported',
        'completion_claim', completion, 'attribution_kind', 'original',
        'named_originator', NULL, 'extraction_confidence', 0.95))));
END;
$$;

-- A 98% reporter-done call makes official completion material only because terminal state changes.
SELECT pg_temp.make_report('official') AS official_report \gset
CREATE TEMPORARY TABLE official_payloads AS
SELECT pg_temp.payload(:official_report, :reporter_id, '2026-05-01', '2026-05-01 12:00+00',
  'done', 'reporter_done') AS reporter_payload,
  pg_temp.payload(:official_report, :official_id, '2026-05-02', '2026-05-02 12:00+00',
  'official_wording', 'official_announcement') AS terminal_payload;
SELECT apply_probability_v1_active(:official_report, reporter_payload)
FROM official_payloads;
INSERT INTO digest_deliveries (
  idempotency_key, channel_key, window_started_at, window_ended_at, status, request_payload
) VALUES ('terminal-frozen', 'transfers', '2026-05-01', '2026-05-02', 'pending',
  '{"frozen":true}'::jsonb) RETURNING id AS delivery_id \gset
INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
SELECT :delivery_id, id, 1 FROM transfer_report_revisions
WHERE transfer_report_id = :official_report ORDER BY revision_number DESC LIMIT 1;
SELECT count(*) AS official_material_before FROM transfer_report_revisions
WHERE transfer_report_id = :official_report \gset
SELECT apply_probability_v1_active(:official_report, terminal_payload)
FROM official_payloads;
SELECT pg_temp.assert_true('active official terminal transition was swallowed by posterior rescore',
  (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :official_report)
    = :official_material_before + 1
  AND (SELECT snapshot #>> '{probability,terminal_state}' = 'official'
    FROM transfer_report_revisions WHERE transfer_report_id = :official_report
    ORDER BY revision_number DESC LIMIT 1)
  AND (SELECT request_payload = '{"frozen":true}'::jsonb
    FROM digest_deliveries WHERE id = :delivery_id)
  AND (SELECT count(*) = 1 FROM digest_items WHERE digest_delivery_id = :delivery_id));

-- A low-delta collapse likewise depends on preserving the first terminal transition.
SELECT pg_temp.make_report('collapse') AS collapse_report \gset
SELECT transfer_case_id AS collapse_case FROM transfer_reports WHERE id = :collapse_report \gset
INSERT INTO source_claim_outcomes (
  source_account_id, transfer_case_id, transfer_report_id,
  first_eligible_stage, claimed_at, outcome_weight
) VALUES (:reporter_id, :collapse_case, :collapse_report, 'advanced', '2026-05-01', 0.5);
INSERT INTO transfer_probability_revisions (
  transfer_report_id, transfer_case_id, revision_number, engine_version, evaluated_at,
  raw_probability, normalized_probability, current_stage, explanation, input_fingerprint
) VALUES (:collapse_report, :collapse_case, 1, 'probability-v1', '2026-05-01',
  0.03, 0.03, 'collapsed', '{}'::jsonb,
  encode(sha256(convert_to('terminal-collapse-prior', 'UTF8')), 'hex'));
UPDATE transfer_reports SET transfer_stage = 'collapsed', raw_probability = 0.03,
  normalized_probability = 0.03, probability_engine_version = 'probability-v1',
  probability_explanation = '{}'::jsonb, probability_updated_at = '2026-05-01',
  probability_status = 'active_scored' WHERE id = :collapse_report;
SELECT pg_temp.payload(:collapse_report, :official_id, '2026-05-02', '2026-05-02 12:00+00',
  'collapsed', 'none', 'collapsed') AS collapse_payload \gset
SELECT count(*) AS collapse_material_before FROM transfer_report_revisions
WHERE transfer_report_id = :collapse_report \gset
SELECT apply_probability_v1_active(:collapse_report, :'collapse_payload'::jsonb);
SELECT pg_temp.assert_true('active collapse terminal transition was swallowed by posterior rescore',
  (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :collapse_report)
    = :collapse_material_before + 1
  AND (SELECT snapshot #>> '{probability,terminal_state}' = 'collapsed'
    FROM transfer_report_revisions WHERE transfer_report_id = :collapse_report
    ORDER BY revision_number DESC LIMIT 1));

ROLLBACK;
