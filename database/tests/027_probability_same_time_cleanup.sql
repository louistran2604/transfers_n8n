DROP TRIGGER IF EXISTS probability_same_time_pause ON source_claim_outcomes;
DROP FUNCTION IF EXISTS probability_same_time_pause();
DROP TABLE IF EXISTS probability_same_time_fixture;
DELETE FROM source_reliability_snapshots WHERE source_account_id IN (
  SELECT id FROM source_accounts WHERE username IN ('sametimerep', 'sametimefc'));
DELETE FROM source_claim_outcomes WHERE transfer_case_id IN (
  SELECT id FROM transfer_cases WHERE case_key LIKE 'same-time-%|old|2026-H2');
DELETE FROM transfer_evidence WHERE transfer_case_id IN (
  SELECT id FROM transfer_cases WHERE case_key LIKE 'same-time-%|old|2026-H2');
DELETE FROM transfer_reports WHERE dedupe_key LIKE 'same-time-%';
DELETE FROM transfer_cases WHERE case_key LIKE 'same-time-%|old|2026-H2';
DELETE FROM raw_posts WHERE source_account_id IN (
  SELECT id FROM source_accounts WHERE username IN ('sametimerep', 'sametimefc'));
DELETE FROM source_accounts WHERE username IN ('sametimerep', 'sametimefc');
DELETE FROM players WHERE identity_key LIKE 'same-time-%';
