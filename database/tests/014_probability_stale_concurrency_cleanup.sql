\set ON_ERROR_STOP on

DROP TRIGGER IF EXISTS probability_stale_concurrency_pause ON transfer_probability_revisions;
DROP TRIGGER IF EXISTS probability_stale_concurrency_record ON transfer_probability_revisions;
DROP FUNCTION IF EXISTS probability_stale_concurrency_pause();
DROP FUNCTION IF EXISTS probability_stale_concurrency_record();
DROP TABLE IF EXISTS probability_stale_concurrency_audit;

DELETE FROM transfer_probability_revisions WHERE transfer_case_id IN (
  SELECT id FROM transfer_cases WHERE case_key LIKE 'stale-concurrency-%|old|2026-H2'
);
DELETE FROM transfer_evidence WHERE transfer_case_id IN (
  SELECT id FROM transfer_cases WHERE case_key LIKE 'stale-concurrency-%|old|2026-H2'
);
DELETE FROM transfer_reports WHERE dedupe_key LIKE 'stale-concurrency-%';
DELETE FROM transfer_cases WHERE case_key LIKE 'stale-concurrency-%|old|2026-H2';
DELETE FROM raw_posts WHERE source_account_id IN (
  SELECT id FROM source_accounts WHERE external_account_id = '940000000000000101'
);
DELETE FROM source_accounts WHERE external_account_id = '940000000000000101';
DELETE FROM players WHERE identity_key LIKE 'stale-concurrency-%';

DO $$
BEGIN
  IF to_regclass('public.probability_stale_concurrency_audit') IS NOT NULL
    OR to_regprocedure('public.probability_stale_concurrency_pause()') IS NOT NULL
    OR to_regprocedure('public.probability_stale_concurrency_record()') IS NOT NULL
    OR EXISTS (SELECT 1 FROM source_accounts WHERE external_account_id = '940000000000000101')
    OR EXISTS (SELECT 1 FROM transfer_cases WHERE case_key LIKE 'stale-concurrency-%|old|2026-H2')
  THEN RAISE EXCEPTION 'stale concurrency fixtures were not fully cleaned'; END IF;
END;
$$;
