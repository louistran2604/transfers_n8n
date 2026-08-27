\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 940000000000000000;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('940000000000000001', 'activetest', 'Active Test', 'individual', 2,
  0.850, 0.850, 'reporter:active-test', 'journalist')
RETURNING id AS source_id \gset

CREATE FUNCTION pg_temp.make_report(label text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint; report_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('active-' || label, 'Active ' || label, 'active ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('active-' || label || '|old-fc|2026-H2', player_id, 'old fc', '2026-H2')
  RETURNING id INTO case_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name,
    destination_club_name, classification, confidence, first_reported_at,
    last_reported_at, transfer_case_id
  ) VALUES (
    'active-' || label || '|old-fc|new-fc', player_id, 'Active ' || label,
    'Old FC', 'New FC', 'rumor', 0.8, '2026-08-01', '2026-08-01', case_id
  ) RETURNING id INTO report_id;
  RETURN report_id;
END;
$$;

CREATE FUNCTION pg_temp.add_core_revision(report_id bigint, active boolean DEFAULT false)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot)
  SELECT report_id, 1, encode(sha256(convert_to('core-' || report_id, 'UTF8')), 'hex'),
    jsonb_build_object(
      'player_name', reported_player_name, 'current_club_name', current_club_name,
      'destination_club_name', destination_club_name, 'classification', classification,
      'move_type', move_type, 'confidence', confidence, 'is_digest_worthy', true
    ) || CASE WHEN active THEN jsonb_build_object('probability_status', 'active_scored') ELSE '{}'::jsonb END
  FROM transfer_reports WHERE id = report_id;
END;
$$;

CREATE FUNCTION pg_temp.add_probability_pair(
  report_id bigint, old_probability numeric, new_probability numeric,
  old_stage text DEFAULT 'talks', new_stage text DEFAULT 'talks',
  old_terminal text DEFAULT NULL, new_terminal text DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE case_id bigint;
BEGIN
  SELECT transfer_case_id INTO case_id FROM transfer_reports WHERE id = report_id;
  INSERT INTO transfer_probability_revisions (
    transfer_report_id, transfer_case_id, revision_number, engine_version, evaluated_at,
    raw_probability, normalized_probability, previous_probability, probability_delta,
    current_stage, explanation, input_fingerprint
  ) VALUES
    (report_id, case_id, 1, 'probability-v1', '2026-08-26 12:00:00+00',
      old_probability, old_probability, NULL, NULL, old_stage,
      jsonb_strip_nulls(jsonb_build_object('terminal_kind', old_terminal)),
      encode(sha256(convert_to('old-' || report_id, 'UTF8')), 'hex')),
    (report_id, case_id, 2, 'probability-v1', '2026-08-27 12:00:00+00',
      new_probability, new_probability, old_probability, new_probability - old_probability,
      new_stage, jsonb_strip_nulls(jsonb_build_object('terminal_kind', new_terminal)),
      encode(sha256(convert_to('new-' || report_id, 'UTF8')), 'hex'));
  UPDATE transfer_reports SET
    transfer_stage = new_stage, raw_probability = new_probability,
    normalized_probability = new_probability, probability_engine_version = 'probability-v1',
    probability_explanation = jsonb_strip_nulls(jsonb_build_object('terminal_kind', new_terminal)),
    probability_updated_at = '2026-08-27 12:00:00+00', probability_status = 'active_scored'
  WHERE id = report_id;
END;
$$;

CREATE FUNCTION pg_temp.material_fixture(
  label text, old_probability numeric, new_probability numeric,
  old_stage text DEFAULT 'talks', new_stage text DEFAULT 'talks',
  old_terminal text DEFAULT NULL, new_terminal text DEFAULT NULL,
  active boolean DEFAULT true
)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE report_id bigint; case_id bigint;
BEGIN
  report_id := pg_temp.make_report(label);
  PERFORM pg_temp.add_core_revision(report_id, active);
  PERFORM pg_temp.add_probability_pair(report_id, old_probability, new_probability,
    old_stage, new_stage, old_terminal, new_terminal);
  SELECT transfer_case_id INTO case_id FROM transfer_reports WHERE id = report_id;
  RETURN promote_probability_v1_case(case_id, '2026-08-27 12:00:00+00');
END;
$$;

SELECT pg_temp.assert_true('initial active score was not promoted',
  pg_temp.material_fixture('initial', 0.40, 0.41, active => false) = 1);
SELECT pg_temp.assert_true('exact 0.05 movement was not promoted',
  pg_temp.material_fixture('exact-five', 0.40, 0.45) = 1);
SELECT pg_temp.assert_true('movement below 0.05 was promoted',
  pg_temp.material_fixture('below-five', 0.40, 0.44999) = 0);
SELECT pg_temp.assert_true('stage progression was not promoted',
  pg_temp.material_fixture('stage-up', 0.40, 0.41, 'talks', 'advanced') = 1);
SELECT pg_temp.assert_true('stage regression was not promoted',
  pg_temp.material_fixture('stage-down', 0.40, 0.41, 'advanced', 'talks') = 1);
SELECT pg_temp.assert_true('official transition was not promoted',
  pg_temp.material_fixture('official', 0.96, 1.00, 'done', 'done', NULL, 'official_confirmation') = 1);
SELECT pg_temp.assert_true('collapse transition was not promoted',
  pg_temp.material_fixture('collapsed', 0.06, 0.02, 'link', 'collapsed', NULL, 'authoritative_collapse') = 1);
SELECT pg_temp.assert_true('reopened transition was not promoted',
  pg_temp.material_fixture('reopened', 0.02, 0.03, 'collapsed', 'link', 'authoritative_collapse', NULL) = 1);

SELECT id AS initial_report_id FROM transfer_reports WHERE dedupe_key = 'active-initial|old-fc|new-fc' \gset
SELECT pg_temp.assert_true('active snapshot is not digest-compatible or complete',
  (SELECT probability_status = 'active_scored' FROM transfer_reports WHERE id = :initial_report_id)
  AND (SELECT snapshot->>'player_name' = 'Active initial'
      AND snapshot->>'probability_status' = 'active_scored'
      AND snapshot #>> '{probability,engine_version}' = 'probability-v1'
      AND snapshot #>> '{probability,current_stage}' = 'talks'
      AND snapshot #>> '{probability,terminal_state}' = 'open'
      AND snapshot #> '{probability,explanation}' IS NOT NULL
    FROM transfer_report_revisions WHERE transfer_report_id = :initial_report_id
    ORDER BY revision_number DESC LIMIT 1));

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('active-leader', 'Active Leader', 'active leader') RETURNING id AS leader_player_id \gset
INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('active-leader|old-fc|2026-H2', :leader_player_id, 'old fc', '2026-H2')
RETURNING id AS leader_case_id \gset
INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
  classification, confidence, first_reported_at, last_reported_at, transfer_case_id
) VALUES
  ('active-leader|old-fc|alpha', :leader_player_id, 'Active Leader', 'Old FC', 'Alpha FC', 'rumor', 0.8, '2026-08-01', '2026-08-01', :leader_case_id),
  ('active-leader|old-fc|beta', :leader_player_id, 'Active Leader', 'Old FC', 'Beta FC', 'rumor', 0.8, '2026-08-01', '2026-08-01', :leader_case_id);
SELECT id AS alpha_id FROM transfer_reports WHERE dedupe_key = 'active-leader|old-fc|alpha' \gset
SELECT id AS beta_id FROM transfer_reports WHERE dedupe_key = 'active-leader|old-fc|beta' \gset
SELECT pg_temp.add_core_revision(:alpha_id, true);
SELECT pg_temp.add_core_revision(:beta_id, true);
SELECT pg_temp.add_probability_pair(:alpha_id, 0.60, 0.49);
SELECT pg_temp.add_probability_pair(:beta_id, 0.40, 0.51);
SELECT pg_temp.assert_true('leader change did not promote every affected destination',
  promote_probability_v1_case(:leader_case_id, '2026-08-27 12:00:00+00') = 2);
SELECT count(*) AS leader_material_count FROM transfer_report_revisions
WHERE transfer_report_id IN (:alpha_id, :beta_id) \gset
SELECT pg_temp.assert_true('identical leader replay duplicated material snapshots',
  promote_probability_v1_case(:leader_case_id, '2026-08-27 12:00:00+00') = 0
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id IN (:alpha_id, :beta_id)) = :leader_material_count);

SELECT pg_temp.make_report('live-mode') AS live_report_id \gset
SELECT pg_temp.add_core_revision(:live_report_id, false);
INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
VALUES (:source_id, nextval('pg_temp.fixture_id')::text, 'https://x.com/activetest/status/live',
  'active live fixture', '2026-08-20 12:00:00+00') RETURNING id AS live_raw_id \gset
CREATE TEMPORARY TABLE live_payload AS SELECT jsonb_build_object(
  'evaluated_at', '2026-08-26T12:00:00Z', 'destination_club_name', 'New FC',
  'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
  'sources', jsonb_build_array(jsonb_build_object(
    'raw_post_id', :live_raw_id, 'posted_at', '2026-08-20T12:00:00Z',
    'report_ordinal', 1, 'extraction_schema_version', 'qwen-evidence-v1',
    'normalized_evidence', jsonb_build_object(
      'stage_signal', 'link', 'claim_stance', 'supports', 'wording_strength', 'direct',
      'club_agreement_state', 'not_reported', 'personal_terms_state', 'not_reported',
      'completion_claim', 'none', 'attribution_kind', 'original',
      'named_originator', NULL, 'extraction_confidence', 0.95
    )))
) AS payload;
SELECT pg_temp.assert_true('off mode produced probability state',
  apply_probability_v1_active(:live_report_id,
    (SELECT payload || jsonb_build_object('probability_mode', 'off') FROM live_payload)) IS NULL
  AND NOT EXISTS (SELECT 1 FROM transfer_evidence WHERE transfer_report_id = :live_report_id));
SELECT apply_probability_v1_shadow(:live_report_id,
  (SELECT payload || jsonb_build_object('probability_mode', 'shadow') FROM live_payload));
SELECT pg_temp.assert_true('shadow mode changed material state or status',
  (SELECT probability_status = 'shadow_scored' FROM transfer_reports WHERE id = :live_report_id)
  AND (SELECT count(*) = 1 FROM transfer_report_revisions WHERE transfer_report_id = :live_report_id));
SELECT apply_probability_v1_active(:live_report_id,
  (SELECT jsonb_set(payload || jsonb_build_object('probability_mode', 'active'), '{evaluated_at}', '"2026-08-27T12:00:00Z"') FROM live_payload));
SELECT pg_temp.assert_true('active mode did not create one composite snapshot',
  (SELECT probability_status = 'active_scored' FROM transfer_reports WHERE id = :live_report_id)
  AND (SELECT count(*) = 2 FROM transfer_report_revisions WHERE transfer_report_id = :live_report_id));
CREATE TEMPORARY TABLE live_counts AS SELECT
  (SELECT count(*) FROM transfer_evidence WHERE transfer_report_id = :live_report_id) evidence,
  (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :live_report_id) probability,
  (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :live_report_id) material,
  (SELECT count(*) FROM digest_items) items,
  (SELECT count(*) FROM digest_deliveries) deliveries;
SELECT apply_probability_v1_active(:live_report_id,
  (SELECT jsonb_set(payload || jsonb_build_object('probability_mode', 'active'), '{evaluated_at}', '"2026-08-27T12:00:00Z"') FROM live_payload));
SELECT pg_temp.assert_true('identical active replay duplicated state or delivery rows',
  (SELECT count(*) FROM transfer_evidence WHERE transfer_report_id = :live_report_id) = (SELECT evidence FROM live_counts)
  AND (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :live_report_id) = (SELECT probability FROM live_counts)
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :live_report_id) = (SELECT material FROM live_counts)
  AND (SELECT count(*) FROM digest_items) = (SELECT items FROM live_counts)
  AND (SELECT count(*) FROM digest_deliveries) = (SELECT deliveries FROM live_counts));

SELECT pg_temp.make_report('decay') AS decay_report_id \gset
SELECT pg_temp.add_core_revision(:decay_report_id, false);
INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
VALUES (:source_id, nextval('pg_temp.fixture_id')::text, 'https://x.com/activetest/status/decay',
  'active decay fixture', '2026-08-01 12:00:00+00') RETURNING id AS decay_raw_id \gset
CREATE TEMPORARY TABLE decay_payload AS SELECT jsonb_build_object(
  'probability_mode', 'active', 'evaluated_at', '2026-08-07T12:00:00Z',
  'destination_club_name', 'New FC',
  'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
  'sources', jsonb_build_array(jsonb_build_object(
    'raw_post_id', :decay_raw_id, 'posted_at', '2026-08-01T12:00:00Z',
    'report_ordinal', 1, 'extraction_schema_version', 'qwen-evidence-v1',
    'normalized_evidence', jsonb_build_object(
      'stage_signal', 'link', 'claim_stance', 'supports', 'wording_strength', 'direct',
      'club_agreement_state', 'not_reported', 'personal_terms_state', 'not_reported',
      'completion_claim', 'none', 'attribution_kind', 'original',
      'named_originator', NULL, 'extraction_confidence', 0.95
    )))
) AS payload;
SELECT apply_probability_v1_active(:decay_report_id, (SELECT payload FROM decay_payload));
CREATE TEMPORARY TABLE decay_before AS SELECT
  (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :decay_report_id) probability,
  (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :decay_report_id) material;
SELECT pg_temp.assert_true('decay case was not selected after crossing its first half-life',
  (SELECT transfer_case_id FROM transfer_reports WHERE id = :decay_report_id)
    IN (SELECT transfer_case_id FROM probability_v1_stale_cases('2026-08-09 12:00:00+00', 100)));
SELECT pg_temp.assert_true('active stale recomputation did not process one case',
  recompute_stale_probability_v1_cases('active', '2026-08-09 12:00:00+00', 100) = 1);
SELECT pg_temp.assert_true('small pure decay did not stay audit-only',
  (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :decay_report_id)
    = (SELECT probability + 1 FROM decay_before)
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :decay_report_id)
    = (SELECT material FROM decay_before)
  AND (SELECT probability_status = 'active_scored' FROM transfer_reports WHERE id = :decay_report_id)
  AND NOT EXISTS (
    SELECT 1 FROM probability_v1_stale_cases('2026-08-09 12:00:00+00', 100)
    WHERE transfer_case_id = (SELECT transfer_case_id FROM transfer_reports WHERE id = :decay_report_id)
  ));

DO $$
DECLARE i integer; player_id bigint; case_id bigint; report_id bigint; raw_id bigint; fixture_source_id bigint;
BEGIN
  SELECT id INTO fixture_source_id FROM source_accounts WHERE username = 'activetest';
  FOR i IN 1..101 LOOP
    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES ('stale-' || i, 'Stale ' || i, 'stale ' || i) RETURNING id INTO player_id;
    INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
    VALUES ('stale-' || i || '|old|2026-H2', player_id, 'old', '2026-H2') RETURNING id INTO case_id;
    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
      classification, confidence, first_reported_at, last_reported_at, transfer_case_id,
      probability_status, probability_engine_version, normalized_probability,
      probability_updated_at, probability_explanation
    ) VALUES ('stale-' || i, player_id, 'Stale ' || i, 'Old', 'New', 'rumor', 0.8,
      '2026-08-01', '2026-08-01', case_id, 'shadow_scored', 'probability-v1', 0.1,
      '2026-08-06 12:00:00+00', '{}'::jsonb) RETURNING id INTO report_id;
    INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
    VALUES (fixture_source_id, nextval('pg_temp.fixture_id')::text, 'https://x.com/activetest/status/stale-' || i,
      'stale fixture', '2026-08-01 12:00:00+00') RETURNING id INTO raw_id;
    INSERT INTO transfer_evidence (
      transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
      report_ordinal, destination_club_name, stage_signal, claim_stance, wording_strength,
      club_agreement_state, personal_terms_state, completion_claim, attribution_kind,
      resolved_independence_key, extraction_confidence, raw_normalized_extraction
    ) VALUES (report_id, case_id, raw_id, 'qwen-evidence-v1', 1, 'New', 'link', 'supports',
      'direct', 'not_reported', 'not_reported', 'none', 'original', 'reporter:active-test', 0.95,
      jsonb_build_object('stage_signal', 'link', 'claim_stance', 'supports', 'wording_strength', 'direct',
        'club_agreement_state', 'not_reported', 'personal_terms_state', 'not_reported',
        'completion_claim', 'none', 'attribution_kind', 'original', 'named_originator', NULL,
        'extraction_confidence', 0.95));
  END LOOP;
END;
$$;
CREATE TEMPORARY TABLE stale_selected AS
SELECT * FROM probability_v1_stale_cases('2026-08-09 12:00:00+00', 100);
SELECT pg_temp.assert_true('stale selector is not stable and bounded to 100',
  (SELECT count(*) = 100 FROM stale_selected)
  AND (SELECT array_agg(transfer_case_id) = array_agg(transfer_case_id ORDER BY transfer_case_id) FROM stale_selected));
UPDATE transfer_reports SET probability_updated_at = '2026-08-09 12:00:00+00'
WHERE transfer_case_id IN (SELECT transfer_case_id FROM stale_selected);
SELECT pg_temp.assert_true('evaluated stale cases were repeatedly selected',
  (SELECT count(*) = 1 FROM probability_v1_stale_cases('2026-08-09 12:00:00+00', 100)));
SELECT pg_temp.assert_true('off stale sweep did work',
  recompute_stale_probability_v1_cases('off', '2026-08-09 12:00:00+00', 100) = 0);

DO $$
BEGIN
  IF (SELECT count(*) FROM app_schema_migrations WHERE version = '007_probability_active_digest') <> 1 THEN
    RAISE EXCEPTION 'Migration 007_probability_active_digest has not been applied exactly once';
  END IF;
END;
$$;

ROLLBACK;

SELECT 'active probability digest tests passed' AS result;
