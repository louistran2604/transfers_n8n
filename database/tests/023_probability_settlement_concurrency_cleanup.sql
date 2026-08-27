DROP TABLE IF EXISTS probability_settlement_concurrency_audit CASCADE;
DROP FUNCTION IF EXISTS probability_settlement_concurrency_audit_trigger() CASCADE;
DELETE FROM source_reliability_snapshots WHERE source_account_id IN (
  SELECT id FROM source_accounts WHERE username LIKE 'settlementlk%'
);
DELETE FROM source_claim_outcomes WHERE transfer_case_id IN (
  SELECT id FROM transfer_cases WHERE case_key LIKE 'settlement-lock-%'
);
DELETE FROM transfer_reports WHERE transfer_case_id IN (
  SELECT id FROM transfer_cases WHERE case_key LIKE 'settlement-lock-%'
);
DELETE FROM transfer_cases WHERE case_key LIKE 'settlement-lock-%';
DELETE FROM players WHERE identity_key LIKE 'settlement-lock-%';
DELETE FROM source_accounts WHERE username LIKE 'settlementlk%';
