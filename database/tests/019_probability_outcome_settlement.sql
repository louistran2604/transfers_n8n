\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 990000000000000000;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES
  ('990000000000000001', 'settlementrep', 'Settlement Reporter', 'individual', 1,
    0.750, 0.750, 'reporter:settlement', 'journalist'),
  ('990000000000000002', 'namedsettler', 'Named Settlement Reporter', 'individual', 1,
    0.800, 0.800, 'reporter:named-settlement', 'journalist'),
  ('990000000000000003', 'settlementagg', 'Settlement Aggregator', 'organization', 5,
    0.650, 0.650, 'publisher:settlement-aggregator', 'aggregator'),
  ('990000000000000004', 'settlementfc', 'Settlement FC', 'organization', 1,
    0.900, 0.900, 'official:settlement-fc', 'club_official'),
  ('990000000000000005', 'announcementrep', 'Announcement Reporter', 'individual', 1,
    0.700, 0.700, 'reporter:announcement', 'journalist');

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('settlement-player', 'Settlement Player', 'settlement player')
RETURNING id AS player_id \gset

INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('settlement-player|old-fc|2026-H1', :player_id, 'old fc', '2026-H1')
RETURNING id AS case_id \gset

INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name,
  destination_club_name, classification, confidence, first_reported_at,
  last_reported_at, transfer_case_id
) VALUES
  ('settlement-player|old-fc|alpha', :player_id, 'Settlement Player', 'Old FC',
    'Alpha FC', 'rumor', 0.8, '2026-05-01', '2026-05-01', :case_id),
  ('settlement-player|old-fc|beta', :player_id, 'Settlement Player', 'Old FC',
    'Beta FC', 'rumor', 0.8, '2026-05-01', '2026-05-01', :case_id);
SELECT id AS alpha_id FROM transfer_reports
WHERE dedupe_key = 'settlement-player|old-fc|alpha' \gset
SELECT id AS beta_id FROM transfer_reports
WHERE dedupe_key = 'settlement-player|old-fc|beta' \gset

CREATE FUNCTION pg_temp.add_evidence(
  account_name text, report_id bigint, posted_at timestamptz, stage text,
  completion text DEFAULT 'none', named_originator text DEFAULT NULL,
  attribution text DEFAULT 'original', confidence_input numeric DEFAULT 0.95,
  club_state text DEFAULT 'not_reported', personal_state text DEFAULT 'not_reported'
) RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE account_id bigint; resolved_id bigint; post_id bigint; case_id bigint;
  source_kind text; source_seed numeric; resolved_username text;
BEGIN
  SELECT id, source_accounts.source_kind, seed_reliability
  INTO account_id, source_kind, source_seed
  FROM source_accounts WHERE username = account_name;
  SELECT transfer_case_id INTO case_id FROM transfer_reports WHERE id = report_id;
  IF named_originator IS NOT NULL THEN
    SELECT id, source_accounts.source_kind, seed_reliability, username
    INTO resolved_id, source_kind, source_seed, resolved_username
    FROM source_accounts
    WHERE lower(username) = lower(regexp_replace(named_originator, '^@', ''));
  ELSE
    resolved_id := account_id;
    resolved_username := account_name;
  END IF;
  INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
  VALUES (account_id, nextval('pg_temp.fixture_id')::text,
    'https://x.com/' || account_name || '/status/' || currval('pg_temp.fixture_id'),
    account_name || ' ' || stage, posted_at) RETURNING id INTO post_id;
  INSERT INTO transfer_evidence (
    transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
    report_ordinal, destination_club_name, stage_signal, claim_stance,
    wording_strength, club_agreement_state, personal_terms_state, completion_claim,
    attribution_kind, named_originator, resolved_independence_key,
    extraction_confidence, raw_normalized_extraction
  ) SELECT report_id, case_id, post_id, 'qwen-evidence-v1', 1,
    destination_club_name, stage, 'supports', 'direct', club_state, personal_state,
    completion, attribution, named_originator,
    CASE WHEN named_originator IS NULL THEN 'source:' || account_id ELSE NULL END,
    confidence_input, jsonb_build_object(
      'stage_signal', stage, 'claim_stance', 'supports', 'wording_strength', 'direct',
      'club_agreement_state', club_state, 'personal_terms_state', personal_state,
      'completion_claim', completion, 'attribution_kind', attribution,
      'named_originator', named_originator, 'extraction_confidence', confidence_input,
      '_resolved_source', jsonb_strip_nulls(jsonb_build_object(
        'account_id', resolved_id, 'username', resolved_username,
        'source_kind', source_kind, 'seed_reliability', source_seed)))
  FROM transfer_reports WHERE id = report_id;
  RETURN post_id;
END;
$$;

SELECT pg_temp.add_evidence('settlementrep', :alpha_id, '2026-05-01 10:00+00', 'advanced');
SELECT pg_temp.add_evidence('settlementrep', :alpha_id, '2026-05-02 10:00+00', 'agreed');
SELECT pg_temp.add_evidence('settlementrep', :beta_id, '2026-05-03 10:00+00', 'done', 'reporter_done');
SELECT pg_temp.add_evidence('settlementagg', :alpha_id, '2026-05-04 10:00+00', 'advanced',
  named_originator => '@namedsettler', attribution => 'cites_named_source');
SELECT pg_temp.add_evidence('settlementfc', :alpha_id, '2026-05-05 10:00+00', 'advanced');
SELECT pg_temp.add_evidence('announcementrep', :alpha_id, '2026-05-04 11:00+00',
  'done', 'official_announcement');

SELECT probability_v1_register_claims(:case_id, '2026-05-04 12:00+00') AS registered \gset
SELECT pg_temp.assert_true('eligible claims were not registered once per resolved source/report',
  :registered = 3
  AND (SELECT count(*) FROM source_claim_outcomes WHERE transfer_case_id = :case_id) = 3);
SELECT pg_temp.assert_true('first stage/time were not preserved or weight was not upgraded monotonically',
  (SELECT first_eligible_stage = 'advanced'
      AND claimed_at = '2026-05-01 10:00+00' AND outcome_weight = 0.75
    FROM source_claim_outcomes outcome JOIN source_accounts source
      ON source.id = outcome.source_account_id
    WHERE source.username = 'settlementrep' AND transfer_report_id = :alpha_id));
SELECT pg_temp.assert_true('named originator was not attributed or official source became a claim',
  EXISTS (SELECT 1 FROM source_claim_outcomes outcome JOIN source_accounts source
    ON source.id = outcome.source_account_id
    WHERE source.username = 'namedsettler' AND transfer_report_id = :alpha_id)
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes outcome JOIN source_accounts source
    ON source.id = outcome.source_account_id
    WHERE source.username IN ('settlementfc', 'announcementrep')));
SELECT pg_temp.assert_true('claim replay was not idempotent',
  probability_v1_register_claims(:case_id, '2026-05-04 12:00+00') = 0
  AND (SELECT count(*) FROM source_claim_outcomes WHERE transfer_case_id = :case_id) = 3);

SELECT pg_temp.add_evidence('settlementfc', :alpha_id, '2026-05-05 12:00+00',
  'official_wording', 'official_announcement') AS official_post_id \gset
SELECT probability_v1_settle_authoritative_claims(
  :case_id, '2026-05-05 13:00+00') AS settled \gset
SELECT pg_temp.assert_true('official settlement did not change every eligible destination claim',
  :settled = 3
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes WHERE transfer_case_id = :case_id
    AND (settlement_outcome IS DISTINCT FROM CASE WHEN transfer_report_id = :alpha_id
      THEN 'success' ELSE 'failure' END
      OR settlement_basis IS DISTINCT FROM 'official_completion'
      OR authoritative_raw_post_id IS DISTINCT FROM :official_post_id)));
SELECT pg_temp.assert_true('weighted beta posterior is not exact',
  (SELECT alpha = 6.75 AND beta = 3.00 AND effective_resolved_count = 1.75
      AND posterior_reliability = 0.6923
    FROM source_reliability_snapshots snapshot JOIN source_accounts source
      ON source.id = snapshot.source_account_id
    WHERE source.username = 'settlementrep'
      AND calculated_at = '2026-05-05 13:00+00'));
SELECT pg_temp.assert_true('settlement replay duplicated rows or snapshots',
  probability_v1_settle_authoritative_claims(:case_id, '2026-05-05 13:00+00') = 0
  AND (SELECT count(*) FROM source_reliability_snapshots
    WHERE calculated_at = '2026-05-05 13:00+00') = 2);

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('collapse-player', 'Collapse Player', 'collapse player')
RETURNING id AS collapse_player_id \gset
INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('collapse-player|old-fc|2026-H2', :collapse_player_id, 'old fc', '2026-H2')
RETURNING id AS collapse_case_id \gset
INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name,
  destination_club_name, classification, confidence, first_reported_at,
  last_reported_at, transfer_case_id
) VALUES
  ('collapse-player|alpha', :collapse_player_id, 'Collapse Player', 'Old FC',
    'Alpha FC', 'rumor', 0.8, '2026-06-01', '2026-06-01', :collapse_case_id),
  ('collapse-player|beta', :collapse_player_id, 'Collapse Player', 'Old FC',
    'Beta FC', 'rumor', 0.8, '2026-06-01', '2026-06-01', :collapse_case_id);
SELECT id AS collapse_alpha_id FROM transfer_reports
WHERE dedupe_key = 'collapse-player|alpha' \gset
SELECT id AS collapse_beta_id FROM transfer_reports
WHERE dedupe_key = 'collapse-player|beta' \gset
SELECT pg_temp.add_evidence('settlementrep', :collapse_alpha_id,
  '2026-06-01 10:00+00', 'advanced');
SELECT pg_temp.add_evidence('settlementrep', :collapse_beta_id,
  '2026-06-01 11:00+00', 'advanced');
SELECT probability_v1_register_claims(:collapse_case_id, '2026-06-02 00:00+00');
SELECT pg_temp.add_evidence('settlementrep', :collapse_alpha_id,
  '2026-06-02 10:00+00', 'collapsed');
SELECT pg_temp.assert_true('non-authoritative collapse settled a claim',
  probability_v1_settle_authoritative_claims(
    :collapse_case_id, '2026-06-02 12:00+00') = 0
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes
    WHERE transfer_case_id = :collapse_case_id AND settlement_outcome IS NOT NULL));
SELECT pg_temp.add_evidence('settlementfc', :collapse_alpha_id,
  '2026-06-03 10:00+00', 'collapsed', club_state => 'collapsed') AS collapse_post_id \gset
SELECT probability_v1_settle_authoritative_claims(
  :collapse_case_id, '2026-06-03 12:00+00') AS collapsed_count \gset
SELECT pg_temp.assert_true('authoritative collapse did not fail only its destination',
  :collapsed_count = 1
  AND (SELECT settlement_outcome = 'failure'
      AND settlement_basis = 'authoritative_collapse'
      AND authoritative_raw_post_id = :collapse_post_id
    FROM source_claim_outcomes WHERE transfer_case_id = :collapse_case_id
      AND transfer_report_id = :collapse_alpha_id)
  AND (SELECT settlement_outcome IS NULL FROM source_claim_outcomes
    WHERE transfer_case_id = :collapse_case_id AND transfer_report_id = :collapse_beta_id));
SELECT alpha AS collapse_alpha, beta AS collapse_beta
FROM source_reliability_snapshots snapshot JOIN source_accounts source
  ON source.id = snapshot.source_account_id
WHERE source.username = 'settlementrep' AND calculated_at = '2026-06-03 12:00+00' \gset
SELECT pg_temp.add_evidence('settlementfc', :collapse_alpha_id,
  '2026-06-04 10:00+00', 'official_wording', 'official_announcement');
SELECT probability_v1_settle_authoritative_claims(
  :collapse_case_id, '2026-06-04 12:00+00') AS corrected_count \gset
SELECT pg_temp.assert_true('later official completion did not supersede collapse immutably',
  :corrected_count = 2
  AND (SELECT settlement_outcome = 'success' AND settlement_basis = 'official_completion'
    FROM source_claim_outcomes WHERE transfer_case_id = :collapse_case_id
      AND transfer_report_id = :collapse_alpha_id)
  AND (SELECT settlement_outcome = 'failure' AND settlement_basis = 'official_completion'
    FROM source_claim_outcomes WHERE transfer_case_id = :collapse_case_id
      AND transfer_report_id = :collapse_beta_id)
  AND (SELECT alpha = :'collapse_alpha' AND beta = :'collapse_beta'
    FROM source_reliability_snapshots snapshot JOIN source_accounts source
      ON source.id = snapshot.source_account_id
    WHERE source.username = 'settlementrep'
      AND calculated_at = '2026-06-03 12:00+00')
  AND EXISTS (SELECT 1 FROM source_reliability_snapshots snapshot
    JOIN source_accounts source ON source.id = snapshot.source_account_id
    WHERE source.username = 'settlementrep'
      AND calculated_at = '2026-06-04 12:00+00'));

ROLLBACK;
