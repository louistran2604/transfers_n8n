\set ON_ERROR_STOP on

DROP TRIGGER IF EXISTS probability_v1_concurrency_pause ON transfer_evidence;
DROP FUNCTION IF EXISTS probability_v1_concurrency_pause();
DROP TABLE IF EXISTS probability_v1_concurrency_fixture;

DELETE FROM transfer_probability_revisions
WHERE transfer_case_id IN (
  SELECT id FROM transfer_cases
  WHERE case_key = 'probability-v1-concurrency|old-fc|2026-H2'
);

DELETE FROM transfer_evidence
WHERE transfer_case_id IN (
    SELECT id FROM transfer_cases
    WHERE case_key = 'probability-v1-concurrency|old-fc|2026-H2'
  )
  OR raw_post_id IN (
    SELECT id FROM raw_posts
    WHERE external_post_id IN (
      '930000000000000201', '930000000000000202',
      '930000000000000203', '930000000000000204'
    )
  );

DELETE FROM transfer_reports
WHERE dedupe_key IN (
  'probability-v1-concurrency|alpha',
  'probability-v1-concurrency|beta'
);

DELETE FROM transfer_cases
WHERE case_key = 'probability-v1-concurrency|old-fc|2026-H2';

DELETE FROM raw_posts
WHERE external_post_id IN (
  '930000000000000201', '930000000000000202',
  '930000000000000203', '930000000000000204'
);

DELETE FROM source_accounts
WHERE external_account_id = '930000000000000101';

DELETE FROM players
WHERE identity_key = 'probability-v1-concurrency';

DO $$
BEGIN
  IF to_regclass('public.probability_v1_concurrency_fixture') IS NOT NULL
    OR to_regprocedure('public.probability_v1_concurrency_pause()') IS NOT NULL
    OR EXISTS (
      SELECT 1 FROM pg_trigger
      WHERE tgname = 'probability_v1_concurrency_pause' AND NOT tgisinternal
    )
    OR EXISTS (
      SELECT 1 FROM source_accounts WHERE external_account_id = '930000000000000101'
    )
    OR EXISTS (
      SELECT 1 FROM players WHERE identity_key = 'probability-v1-concurrency'
    )
    OR EXISTS (
      SELECT 1 FROM transfer_cases
      WHERE case_key = 'probability-v1-concurrency|old-fc|2026-H2'
    )
    OR EXISTS (
      SELECT 1 FROM transfer_reports
      WHERE dedupe_key IN (
        'probability-v1-concurrency|alpha',
        'probability-v1-concurrency|beta'
      )
    )
    OR EXISTS (
      SELECT 1 FROM raw_posts
      WHERE external_post_id IN (
        '930000000000000201', '930000000000000202',
        '930000000000000203', '930000000000000204'
      )
    )
  THEN
    RAISE EXCEPTION 'probability-v1 concurrency fixtures were not fully cleaned';
  END IF;
END;
$$;

SELECT 'probability-v1 concurrency fixtures cleaned' AS result;
