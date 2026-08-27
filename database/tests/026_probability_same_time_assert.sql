\set ON_ERROR_STOP on

DO $$
DECLARE reporter_id bigint; snapshot_count integer; latest record;
BEGIN
  SELECT id INTO reporter_id FROM source_accounts WHERE username = 'sametimerep';
  SELECT count(*) INTO snapshot_count FROM source_reliability_snapshots
  WHERE source_account_id = reporter_id AND engine_version = 'probability-v1'
    AND calculated_at = '2026-04-03 00:00+00';
  SELECT alpha, beta, effective_resolved_count INTO latest
  FROM source_reliability_snapshots
  WHERE source_account_id = reporter_id AND engine_version = 'probability-v1'
    AND calculated_at = '2026-04-03 00:00+00'
  ORDER BY id DESC LIMIT 1;
  IF snapshot_count <> 2 OR latest.alpha <> 7 OR latest.beta <> 2
      OR latest.effective_resolved_count <> 1 THEN
    RAISE EXCEPTION 'same-time posterior is incomplete: count %, alpha %, beta %, effective %',
      snapshot_count, latest.alpha, latest.beta, latest.effective_resolved_count;
  END IF;
  IF probability_v1_settle_authoritative_claims(
      (SELECT transfer_case_id FROM probability_same_time_fixture WHERE label = '1'),
      '2026-04-03 00:00+00') <> 0
    OR (SELECT count(*) FROM source_reliability_snapshots
      WHERE source_account_id = reporter_id AND calculated_at = '2026-04-03 00:00+00') <> 2 THEN
    RAISE EXCEPTION 'same-time replay duplicated settlement or snapshot';
  END IF;
END;
$$;
