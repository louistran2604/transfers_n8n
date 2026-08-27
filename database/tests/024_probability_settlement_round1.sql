\set ON_ERROR_STOP on

BEGIN;

CREATE TEMPORARY TABLE round1_failures (label text PRIMARY KEY);
CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN
    INSERT INTO round1_failures VALUES (label) ON CONFLICT DO NOTHING;
  END IF;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 994000000000000000;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES
  ('994000000000000001', 'roundonerep', 'Round One Reporter', 'individual', 1,
    0.75, 0.75, 'reporter:round-one', 'journalist'),
  ('994000000000000002', 'roundonefc', 'Round One FC', 'organization', 1,
    0.90, 0.90, 'official:round-one', 'club_official');
SELECT id AS reporter_id FROM source_accounts WHERE username = 'roundonerep' \gset
SELECT id AS official_id FROM source_accounts WHERE username = 'roundonefc' \gset

CREATE FUNCTION pg_temp.make_case(label text, window_key text DEFAULT '2026-H2')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('round-one-' || label, 'Round One ' || label, 'round one ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('round-one-' || label || '|old|' || window_key, player_id, 'old', window_key)
  RETURNING id INTO case_id;
  RETURN case_id;
END;
$$;

CREATE FUNCTION pg_temp.make_report(case_id bigint, label text, destination text)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; report_id bigint;
BEGIN
  SELECT transfer_cases.player_id INTO player_id FROM transfer_cases WHERE id = case_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name,
    destination_club_name, classification, confidence, first_reported_at,
    last_reported_at, transfer_case_id
  ) VALUES ('round-one-' || label, player_id, 'Round One ' || label, 'Old FC',
    destination, 'rumor', 0.8, '2026-01-01', '2026-01-01', case_id)
  RETURNING id INTO report_id;
  RETURN report_id;
END;
$$;

CREATE FUNCTION pg_temp.add_evidence(
  report_id bigint, source_id bigint, posted_at timestamptz, stage text,
  completion text DEFAULT 'none', club_state text DEFAULT 'not_reported',
  personal_state text DEFAULT 'not_reported'
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE post_id bigint; case_id bigint; destination text; resolved_username text;
  resolved_kind text; resolved_seed numeric; independence_key text;
BEGIN
  SELECT transfer_case_id, destination_club_name INTO case_id, destination
  FROM transfer_reports WHERE id = report_id;
  SELECT username, source_kind, seed_reliability,
    COALESCE(publisher_group_key, 'source:' || id)
  INTO resolved_username, resolved_kind, resolved_seed, independence_key
  FROM source_accounts WHERE id = source_id;
  INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
  VALUES (source_id, nextval('pg_temp.fixture_id')::text,
    'https://x.com/' || resolved_username || '/status/' || currval('pg_temp.fixture_id'),
    stage, posted_at) RETURNING id INTO post_id;
  INSERT INTO transfer_evidence (
    transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
    report_ordinal, destination_club_name, stage_signal, claim_stance,
    wording_strength, club_agreement_state, personal_terms_state, completion_claim,
    attribution_kind, resolved_independence_key, extraction_confidence,
    raw_normalized_extraction
  ) VALUES (report_id, case_id, post_id, 'qwen-evidence-v1', 1,
    destination, stage, 'supports', 'direct', club_state, personal_state,
    completion, 'original', independence_key, 0.95,
    jsonb_build_object(
      'stage_signal', stage, 'claim_stance', 'supports', 'wording_strength', 'direct',
      'club_agreement_state', club_state, 'personal_terms_state', personal_state,
      'completion_claim', completion, 'attribution_kind', 'original',
      'named_originator', NULL, 'extraction_confidence', 0.95,
      '_resolved_source', jsonb_build_object('account_id', source_id,
        'username', resolved_username, 'source_kind', resolved_kind,
        'seed_reliability', resolved_seed)));
  RETURN post_id;
END;
$$;

-- not_applicable alone is not an agreed gate.
SELECT pg_temp.make_case('not-applicable') AS na_case \gset
SELECT pg_temp.make_report(:na_case, 'not-applicable', 'Free FC') AS na_report \gset
SELECT pg_temp.add_evidence(:na_report, :reporter_id, '2026-01-01', 'interest',
  club_state => 'not_applicable');
SELECT pg_temp.assert_true('not_applicable created a 0.75 reporter claim',
  probability_v1_register_claims(:na_case, '2026-01-02') = 0
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes WHERE transfer_case_id = :na_case));

-- Completion is case-wide; collapse is destination-specific and both cut off later claims.
SELECT pg_temp.make_case('post-authority') AS authority_case \gset
SELECT pg_temp.make_report(:authority_case, 'authority-alpha', 'Alpha FC') AS authority_alpha \gset
SELECT pg_temp.make_report(:authority_case, 'authority-beta', 'Beta FC') AS authority_beta \gset
SELECT pg_temp.add_evidence(:authority_alpha, :official_id, '2026-01-01',
  'official_wording', 'official_announcement');
SELECT pg_temp.add_evidence(:authority_alpha, :reporter_id, '2026-01-02', 'advanced');
SELECT pg_temp.add_evidence(:authority_beta, :reporter_id, '2026-01-02', 'advanced');
SELECT pg_temp.assert_true('claims after case-wide official completion were registered',
  probability_v1_register_claims(:authority_case, '2026-01-03') = 0);

SELECT pg_temp.make_case('post-collapse') AS collapse_case \gset
SELECT pg_temp.make_report(:collapse_case, 'collapse-alpha-late', 'Alpha FC') AS collapse_alpha \gset
SELECT pg_temp.make_report(:collapse_case, 'collapse-beta-live', 'Beta FC') AS collapse_beta \gset
SELECT pg_temp.add_evidence(:collapse_alpha, :official_id, '2026-02-01',
  'collapsed', club_state => 'collapsed');
SELECT pg_temp.add_evidence(:collapse_alpha, :reporter_id, '2026-02-02', 'advanced');
SELECT pg_temp.add_evidence(:collapse_beta, :reporter_id, '2026-02-02', 'advanced');
SELECT probability_v1_register_claims(
  :collapse_case, '2026-02-03') AS collapse_registered \gset
SELECT pg_temp.assert_true('collapse cutoff was not destination-specific',
  :collapse_registered = 1
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes
    WHERE transfer_report_id = :collapse_alpha)
  AND EXISTS (SELECT 1 FROM source_claim_outcomes
    WHERE transfer_report_id = :collapse_beta));

-- Posterior time travel excludes settlements after the requested snapshot time.
SELECT pg_temp.make_case('backdated-one') AS back_case_one \gset
SELECT pg_temp.make_report(:back_case_one, 'backdated-one', 'One FC') AS back_report_one \gset
SELECT pg_temp.make_case('backdated-two') AS back_case_two \gset
SELECT pg_temp.make_report(:back_case_two, 'backdated-two', 'Two FC') AS back_report_two \gset
INSERT INTO source_claim_outcomes (
  source_account_id, transfer_case_id, transfer_report_id, first_eligible_stage,
  claimed_at, settlement_outcome, outcome_weight, settlement_basis, settled_at
) VALUES
  (:reporter_id, :back_case_one, :back_report_one, 'advanced', '2026-01-01',
    'failure', 0.5, 'window_expiry', '2026-01-10'),
  (:reporter_id, :back_case_two, :back_report_two, 'advanced', '2026-01-01',
    'failure', 1.0, 'window_expiry', '2026-02-10');
SELECT probability_v1_append_reliability_snapshots(
  ARRAY[:reporter_id], '2026-01-15') AS backdated_snapshot_count \gset
SELECT pg_temp.assert_true('backdated posterior included a future settlement',
  :backdated_snapshot_count = 1
  AND (SELECT alpha = 6 AND beta = 2.5 AND effective_resolved_count = 0.5
    FROM source_reliability_snapshots
    WHERE source_account_id = :reporter_id AND calculated_at = '2026-01-15'));

-- Constraint must reject collapse successes.
CREATE FUNCTION pg_temp.collapse_success_allowed(requested_report_id bigint)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    UPDATE source_claim_outcomes
    SET settlement_outcome = 'success', settlement_basis = 'authoritative_collapse',
        authoritative_raw_post_id = (SELECT min(id) FROM raw_posts), settled_at = '2026-03-01'
    WHERE transfer_report_id = requested_report_id;
    RETURN true;
  EXCEPTION WHEN check_violation THEN RETURN false;
  END;
END;
$$;
SELECT pg_temp.assert_true('authoritative collapse accepted a success outcome',
  NOT pg_temp.collapse_success_allowed(:back_report_one));

-- One call drains more than one bounded batch of affected cases.
DO $$
DECLARE i integer; case_id bigint; report_id bigint; raw_id bigint; player_id bigint;
  fixture_source_id bigint;
BEGIN
  SELECT id INTO fixture_source_id FROM source_accounts WHERE username = 'roundonerep';
  FOR i IN 1..101 LOOP
    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES ('round-one-drain-' || i, 'Drain ' || i, 'drain ' || i) RETURNING id INTO player_id;
    INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
    VALUES ('round-one-drain-' || i || '|old|2026-H2', player_id, 'old', '2026-H2')
    RETURNING id INTO case_id;
    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
      classification, confidence, first_reported_at, last_reported_at, transfer_case_id,
      transfer_stage, probability_status, probability_engine_version,
      raw_probability, normalized_probability, probability_updated_at,
      probability_explanation
    ) VALUES ('round-one-drain-' || i, player_id, 'Drain ' || i, 'Old', 'New',
      'rumor', 0.8, '2026-03-01', '2026-03-01', case_id, 'advanced',
      'shadow_scored', 'probability-v1', 0.5, 0.5, '2026-03-01', '{}'::jsonb)
    RETURNING id INTO report_id;
    INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
    VALUES (fixture_source_id, nextval('pg_temp.fixture_id')::text,
      'https://x.com/roundonerep/status/' || currval('pg_temp.fixture_id'),
      'advanced', '2026-03-01') RETURNING id INTO raw_id;
    INSERT INTO transfer_evidence (
      transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
      report_ordinal, destination_club_name, stage_signal, claim_stance, wording_strength,
      club_agreement_state, personal_terms_state, completion_claim, attribution_kind,
      resolved_independence_key, extraction_confidence, raw_normalized_extraction
    ) VALUES (report_id, case_id, raw_id, 'qwen-evidence-v1', 1, 'New', 'advanced',
      'supports', 'direct', 'talks', 'talks', 'none', 'original', 'reporter:round-one', 0.95,
      jsonb_build_object('stage_signal', 'advanced', 'claim_stance', 'supports',
        'wording_strength', 'direct', 'club_agreement_state', 'talks',
        'personal_terms_state', 'talks', 'completion_claim', 'none',
        'attribution_kind', 'original', 'named_originator', NULL,
        'extraction_confidence', 0.95, '_resolved_source', jsonb_build_object(
          'account_id', fixture_source_id, 'username', 'roundonerep',
          'source_kind', 'journalist', 'seed_reliability', 0.75)));
  END LOOP;
END;
$$;
INSERT INTO source_reliability_snapshots (
  source_account_id, engine_version, alpha, beta, effective_resolved_count,
  posterior_reliability, calculated_at
) VALUES (:reporter_id, 'probability-v1', 7, 2, 2, 0.7778, '2026-03-02');
SELECT recompute_probability_v1_reporter_cases(
  'shadow', '2026-03-02', NULL, 100) AS drained_count \gset
SELECT pg_temp.assert_true('affected reporter cases were stranded after the first 100',
  :drained_count = 101
  AND (SELECT count(*) = 101 FROM transfer_reports
    WHERE dedupe_key LIKE 'round-one-drain-%'
      AND probability_updated_at = '2026-03-02'));
SELECT pg_temp.assert_true('affected-case drain replay was not idempotent',
  recompute_probability_v1_reporter_cases('shadow', '2026-03-02', NULL, 100) = 0);
INSERT INTO source_reliability_snapshots (
  source_account_id, engine_version, alpha, beta, effective_resolved_count,
  posterior_reliability, calculated_at, posterior_fingerprint
) VALUES (:reporter_id, 'probability-v1', 8, 2, 3, 0.8, '2026-03-02', repeat('b', 64));
SELECT recompute_probability_v1_reporter_cases(
  'shadow', '2026-03-02', NULL, 100) AS same_time_rescore_count \gset
SELECT pg_temp.assert_true('newer same-time posterior did not rescore already evaluated cases',
  :same_time_rescore_count = 101
  AND recompute_probability_v1_reporter_cases(
    'shadow', '2026-03-02', NULL, 100) = 0);

DO $$
DECLARE failed_labels text;
BEGIN
  SELECT string_agg(label, '; ' ORDER BY label) INTO failed_labels FROM round1_failures;
  IF failed_labels IS NOT NULL THEN RAISE EXCEPTION '%', failed_labels; END IF;
END;
$$;

ROLLBACK;
