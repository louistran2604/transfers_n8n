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
) VALUES
  ('991000000000000001', 'boundaryhigh', 'Boundary High', 'individual', 1,
    0.990, 0.990, 'reporter:boundary-high', 'journalist'),
  ('991000000000000002', 'boundarylow', 'Boundary Low', 'individual', 1,
    0.100, 0.100, 'reporter:boundary-low', 'journalist'),
  ('991000000000000003', 'boundaryclamp', 'Boundary Clamp', 'individual', 1,
    0.990, 0.990, 'reporter:boundary-clamp', 'journalist');
SELECT id AS high_source_id FROM source_accounts WHERE username = 'boundaryhigh' \gset
SELECT id AS low_source_id FROM source_accounts WHERE username = 'boundarylow' \gset
SELECT id AS clamp_source_id FROM source_accounts WHERE username = 'boundaryclamp' \gset

CREATE FUNCTION pg_temp.make_case(label text, window_key text, source_id bigint)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint; report_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('boundary-' || label, 'Boundary ' || label, 'boundary ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('boundary-' || label || '|old-fc|' || window_key, player_id, 'old fc', window_key)
  RETURNING id INTO case_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name,
    destination_club_name, classification, confidence, first_reported_at,
    last_reported_at, transfer_case_id
  ) VALUES ('boundary-' || label, player_id, 'Boundary ' || label, 'Old FC',
    'New FC', 'rumor', 0.8, '2026-01-01', '2026-01-01', case_id)
  RETURNING id INTO report_id;
  INSERT INTO source_claim_outcomes (
    source_account_id, transfer_case_id, transfer_report_id,
    first_eligible_stage, claimed_at, outcome_weight
  ) VALUES (source_id, case_id, report_id, 'advanced', '2026-01-01', 0.5);
  RETURN case_id;
END;
$$;

SELECT pg_temp.make_case('h1-a', '2026-H1', :high_source_id) AS h1_a \gset
SELECT pg_temp.make_case('h1-b', '2026-H1', :high_source_id) AS h1_b \gset
SELECT pg_temp.make_case('h1-c', '2026-H1', :high_source_id) AS h1_c \gset
SELECT pg_temp.make_case('h2', '2026-H2', :low_source_id) AS h2_case \gset

SELECT pg_temp.assert_true('calendar-half expiry timestamps are not exact UTC boundaries',
  probability_v1_window_expiry_at('2026-H1') = '2026-07-15 00:00:00+00'
  AND probability_v1_window_expiry_at('2026-H2') = '2027-01-15 00:00:00+00');
SELECT pg_temp.assert_true('off mode or one instant before H1 expiry settled claims',
  settle_expired_probability_v1_cases('off', '2026-07-15 00:00:00+00', 100) = 0
  AND settle_expired_probability_v1_cases('shadow', '2026-07-14 23:59:59.999999+00', 100) = 0
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes WHERE transfer_case_id IN (:h1_a, :h1_b, :h1_c)
    AND settlement_outcome IS NOT NULL));
SELECT settle_expired_probability_v1_cases(
  'shadow', '2026-07-15 00:00:00+00', 2) AS first_batch \gset
SELECT pg_temp.assert_true('fixed H1 batch did not settle exactly two cases at eligibility',
  :first_batch = 2
  AND (SELECT count(*) FROM transfer_cases
    WHERE id IN (:h1_a, :h1_b, :h1_c) AND status = 'closed') = 2);
SELECT settle_expired_probability_v1_cases(
  'shadow', '2026-07-15 00:00:00.000001+00', 100) AS remaining_batch \gset
SELECT settle_expired_probability_v1_cases(
  'shadow', '2026-07-15 00:00:00.000001+00', 100) AS replay_batch \gset
SELECT pg_temp.assert_true('remaining H1 case was not settled once or replay was not idempotent',
  :remaining_batch = 1 AND :replay_batch = 0
  AND NOT EXISTS (SELECT 1 FROM source_claim_outcomes
    WHERE transfer_case_id IN (:h1_a, :h1_b, :h1_c)
      AND (settlement_outcome <> 'failure' OR settlement_basis <> 'window_expiry'
        OR authoritative_raw_post_id IS NOT NULL
        OR authoritative_transfer_report_revision_id IS NOT NULL)));
SELECT pg_temp.assert_true('fixed batch snapshots did not include every settled outcome',
  (SELECT effective_resolved_count = 1.5 AND alpha = 7.92 AND beta = 1.58
    FROM source_reliability_snapshots
    WHERE source_account_id = :high_source_id
      AND calculated_at = '2026-07-15 00:00:00.000001+00'
    ORDER BY id DESC LIMIT 1));
SELECT pg_temp.assert_true('H2 settled before its exact grace boundary',
  settle_expired_probability_v1_cases('active', '2027-01-14 23:59:59.999999+00', 100) = 0
  AND (SELECT settlement_outcome IS NULL FROM source_claim_outcomes
    WHERE transfer_case_id = :h2_case));
SELECT settle_expired_probability_v1_cases(
  'active', '2027-01-15 00:00:00+00', 100) AS h2_batch \gset
SELECT pg_temp.assert_true('H2 did not settle exactly at its grace boundary',
  :h2_batch = 1
  AND (SELECT status = 'closed' FROM transfer_cases WHERE id = :h2_case));

INSERT INTO source_claim_outcomes (
  source_account_id, transfer_case_id, transfer_report_id,
  first_eligible_stage, claimed_at, outcome_weight
) SELECT :low_source_id, transfer_case_id, id, 'advanced', '2026-01-01', 0.5
FROM transfer_reports WHERE transfer_case_id = :h1_a;
SELECT probability_v1_append_reliability_snapshots(
  ARRAY[:clamp_source_id, :low_source_id], '2027-02-01 00:00+00');
SELECT pg_temp.assert_true('posterior clamps or pending exclusion are wrong',
  (SELECT posterior_reliability = 0.95 FROM source_reliability_snapshots
    WHERE source_account_id = :clamp_source_id AND calculated_at = '2027-02-01 00:00+00')
  AND (SELECT posterior_reliability = 0.55 AND effective_resolved_count = 0.5
    FROM source_reliability_snapshots
    WHERE source_account_id = :low_source_id AND calculated_at = '2027-02-01 00:00+00'));

ROLLBACK;
