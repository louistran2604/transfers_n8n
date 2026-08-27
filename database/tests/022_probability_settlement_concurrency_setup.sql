\set ON_ERROR_STOP on

\i /database/tests/023_probability_settlement_concurrency_cleanup.sql

CREATE TABLE probability_settlement_concurrency_audit (
  transfer_case_id bigint PRIMARY KEY,
  backend_pid integer NOT NULL
);

DO $$
DECLARE source_ids bigint[] := '{}'::bigint[]; source_id bigint;
  player_id bigint; case_id bigint; report_id bigint;
BEGIN
  FOR fixture_number IN 1..2 LOOP
    INSERT INTO source_accounts (
      external_account_id, username, display_name, account_type, priority_rank,
      reliability_score, seed_reliability, publisher_group_key, source_kind
    ) VALUES ('99300000000000000' || fixture_number,
      'settlementlk' || fixture_number, 'Settlement Lock', 'individual', 1,
      0.75, 0.75, 'reporter:settlement-lock-' || fixture_number, 'journalist')
    RETURNING id INTO source_id;
    source_ids := array_append(source_ids, source_id);
  END LOOP;

  FOR fixture_number IN 1..8 LOOP
    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES ('settlement-lock-' || fixture_number, 'Settlement Lock', 'settlement lock')
    RETURNING id INTO player_id;
    INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
    VALUES ('settlement-lock-' || fixture_number || '|2026-H1', player_id, 'old fc', '2026-H1')
    RETURNING id INTO case_id;
    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name,
      destination_club_name, classification, confidence, first_reported_at,
      last_reported_at, transfer_case_id
    ) VALUES ('settlement-lock-' || fixture_number, player_id, 'Settlement Lock',
      'Old FC', 'New FC', 'rumor', 0.8, '2026-01-01', '2026-01-01', case_id)
    RETURNING id INTO report_id;
    INSERT INTO source_claim_outcomes (
      source_account_id, transfer_case_id, transfer_report_id,
      first_eligible_stage, claimed_at, outcome_weight
    ) VALUES (
      source_ids[CASE WHEN fixture_number IN (1, 2, 7, 8) THEN 2 ELSE 1 END],
      case_id, report_id, 'advanced', '2026-01-01', 0.5
    );
  END LOOP;
END;
$$;

CREATE FUNCTION probability_settlement_concurrency_audit_trigger()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM transfer_cases
      WHERE id = NEW.transfer_case_id
        AND case_key IN ('settlement-lock-1|2026-H1', 'settlement-lock-2|2026-H1')) THEN
    PERFORM pg_advisory_lock(940009);
  ELSIF EXISTS (SELECT 1 FROM transfer_cases
      WHERE id = NEW.transfer_case_id
        AND case_key IN ('settlement-lock-3|2026-H1', 'settlement-lock-4|2026-H1')) THEN
    PERFORM pg_advisory_lock(940010);
  END IF;
  INSERT INTO probability_settlement_concurrency_audit (transfer_case_id, backend_pid)
  VALUES (NEW.transfer_case_id, pg_backend_pid());
  RETURN NEW;
END;
$$;

CREATE TRIGGER probability_settlement_concurrency_audit_after_update
AFTER UPDATE OF settlement_outcome ON source_claim_outcomes
FOR EACH ROW
WHEN (OLD.settlement_outcome IS NULL AND NEW.settlement_outcome IS NOT NULL)
EXECUTE FUNCTION probability_settlement_concurrency_audit_trigger();
