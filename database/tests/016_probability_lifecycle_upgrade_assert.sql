\set ON_ERROR_STOP on

DO $$
DECLARE stale_case_keys text[];
BEGIN
  SELECT array_agg(transfer_case.case_key ORDER BY transfer_case.case_key)
  INTO stale_case_keys
  FROM probability_v1_stale_cases('2026-08-09 12:00:00+00', 100) stale
  JOIN transfer_cases transfer_case ON transfer_case.id = stale.transfer_case_id
  WHERE transfer_case.case_key LIKE 'lifecycle-upgrade-%';

  IF (SELECT status FROM transfer_cases WHERE case_key = 'lifecycle-upgrade-official|old|2026-H2') <> 'completed'
    OR (SELECT status FROM transfer_cases WHERE case_key = 'lifecycle-upgrade-collapsed|old|2026-H2') <> 'collapsed'
    OR (SELECT status FROM transfer_cases WHERE case_key = 'lifecycle-upgrade-mixed|old|2026-H2') <> 'open'
    OR (SELECT status FROM transfer_cases WHERE case_key = 'lifecycle-upgrade-closed|old|2026-H2') <> 'closed'
    OR stale_case_keys IS DISTINCT FROM ARRAY['lifecycle-upgrade-mixed|old|2026-H2']::text[]
  THEN
    RAISE EXCEPTION 'pre-007 probability lifecycle was not synchronized; stale cases=%', stale_case_keys;
  END IF;
END;
$$;

SELECT 'probability lifecycle upgrade test passed' AS result;
