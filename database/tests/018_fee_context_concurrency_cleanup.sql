\set ON_ERROR_STOP on

DROP FUNCTION IF EXISTS fee_context_concurrency_mutate();
DROP TABLE IF EXISTS fee_context_concurrency_fixture;
DROP SEQUENCE IF EXISTS fee_context_concurrency_id;

DELETE FROM digest_deliveries WHERE idempotency_key = 'fee-concurrency-pending';
DELETE FROM transfer_reports WHERE dedupe_key LIKE 'fee-concurrency-%';
DELETE FROM player_profile_snapshots WHERE stable_source_identifier LIKE 'sofascore:fee-concurrency:%';
DELETE FROM player_provider_ids WHERE canonical_name LIKE 'Fee Concurrency %';
DELETE FROM players WHERE identity_key LIKE 'fee-concurrency-%';

DO $$
BEGIN
  IF to_regclass('public.fee_context_concurrency_fixture') IS NOT NULL
    OR to_regprocedure('public.fee_context_concurrency_mutate()') IS NOT NULL
    OR EXISTS (SELECT 1 FROM digest_deliveries WHERE idempotency_key = 'fee-concurrency-pending')
    OR EXISTS (SELECT 1 FROM transfer_reports WHERE dedupe_key LIKE 'fee-concurrency-%')
    OR EXISTS (SELECT 1 FROM players WHERE identity_key LIKE 'fee-concurrency-%')
  THEN RAISE EXCEPTION 'fee-context concurrency fixtures were not fully cleaned'; END IF;
END;
$$;
