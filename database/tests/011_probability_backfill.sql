\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION '%', label;
  END IF;
END;
$$;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('930000000000000001', 'backfilltest', 'Backfill Test', 'individual', 2,
  0.850, 0.850, 'reporter:backfill-test', 'journalist')
RETURNING id AS source_id \gset

INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
SELECT :source_id, (930000000000000100 + value)::text,
  'https://x.com/backfilltest/status/' || (930000000000000100 + value)::text,
  'backfill fixture ' || value,
  CASE value
    WHEN 1 THEN '2026-07-28 11:59:59+00'::timestamptz
    WHEN 2 THEN '2026-07-28 12:00:00+00'::timestamptz
    ELSE '2026-07-28 12:00:00+00'::timestamptz + value * interval '1 minute'
  END
FROM generate_series(1, 103) value;

CREATE TEMPORARY TABLE first_claim AS
SELECT * FROM claim_probability_backfill(
  'shadow', '2026-08-27 12:00:00+00', 'run-a', 'qwen-evidence-v1', 100, interval '15 minutes'
);

SELECT pg_temp.assert_true('30-day cutoff or batch size is wrong',
  (SELECT count(*) = 100 FROM first_claim)
  AND NOT EXISTS (SELECT 1 FROM first_claim WHERE external_post_id = '930000000000000101'));
SELECT pg_temp.assert_true('claim order is not stable oldest-first',
  (SELECT array_agg(raw_post_id ORDER BY claim_ordinal) = array_agg(raw_post_id ORDER BY posted_at, raw_post_id)
   FROM first_claim));
SELECT pg_temp.assert_true('non-shadow mode claimed rows',
  NOT EXISTS (SELECT 1 FROM claim_probability_backfill(
    'active', '2026-08-27 12:00:00+00', 'run-off', 'qwen-evidence-v1', 100, interval '15 minutes')));
CREATE TEMPORARY TABLE second_claim AS
SELECT * FROM claim_probability_backfill(
  'shadow', '2026-08-27 12:00:00+00', 'run-b', 'qwen-evidence-v1', 100, interval '15 minutes'
);
SELECT pg_temp.assert_true('double claim returned leased rows',
  (SELECT count(*) = 2 FROM second_claim)
  AND NOT EXISTS (SELECT 1 FROM first_claim JOIN second_claim USING (raw_post_id)));

SELECT raw_post_id AS transfer_raw_id FROM first_claim ORDER BY claim_ordinal LIMIT 1 \gset
SELECT raw_post_id AS ignored_raw_id FROM first_claim ORDER BY claim_ordinal OFFSET 1 LIMIT 1 \gset

SELECT complete_probability_backfill(
  :ignored_raw_id, 'qwen-evidence-v1', 'run-a', '2026-08-27 12:00:00+00', '[]'::jsonb
);

CREATE TEMPORARY TABLE before_material AS
SELECT
  (SELECT count(*) FROM transfer_report_revisions) AS revisions,
  (SELECT count(*) FROM digest_items) AS items,
  (SELECT count(*) FROM digest_deliveries) AS deliveries,
  (SELECT coalesce(jsonb_agg(request_payload ORDER BY id), '[]'::jsonb) FROM digest_deliveries) AS payloads;

SELECT complete_probability_backfill(
  :transfer_raw_id,
  'qwen-evidence-v1',
  'run-a',
  '2026-08-27 12:00:00+00',
  jsonb_build_array(jsonb_build_object(
    'dedupe_key', 'backfill-player|old-fc|new-fc',
    'player_identity_key', 'backfill-player',
    'player_name', 'Backfill Player',
    'normalized_player_name', 'backfill player',
    'current_club_name', 'Old FC',
    'destination_club_name', 'New FC',
    'classification', 'rumor',
    'move_type', 'permanent',
    'medical_status', 'not_reported',
    'agreement_status', 'not_reported',
    'extraction_confidence', 0.9,
    'first_reported_at', '2026-07-28T12:00:00Z',
    'last_reported_at', '2026-07-28T12:00:00Z',
    'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
    'evaluated_at', '2026-08-27T12:00:00Z',
    'probability_mode', 'shadow',
    'sources', jsonb_build_array(jsonb_build_object(
      'raw_post_id', :transfer_raw_id::text,
      'posted_at', '2026-07-28T12:00:00Z',
      'report_ordinal', 1,
      'extraction_schema_version', 'qwen-evidence-v1',
      'normalized_evidence', jsonb_build_object(
        'stage_signal', 'advanced', 'claim_stance', 'supports',
        'wording_strength', 'direct', 'club_agreement_state', 'talks',
        'personal_terms_state', 'talks', 'completion_claim', 'none',
        'attribution_kind', 'original', 'named_originator', NULL,
        'extraction_confidence', 0.9
      )
    ))
  ))
);

CREATE TEMPORARY TABLE idempotency_before AS
SELECT
  (SELECT count(*) FROM probability_backfill_replays) AS replay_count,
  (SELECT count(*) FROM transfer_evidence) AS evidence_count,
  (SELECT count(*) FROM transfer_probability_revisions) AS probability_count,
  (SELECT coalesce(sum(version_counter), 0) FROM transfer_cases) AS version_count;

SELECT pg_temp.assert_true('completion status/projection is wrong',
  (SELECT outcome = 'non_transfer' AND completed_at IS NOT NULL
   FROM probability_backfill_replays WHERE raw_post_id = :ignored_raw_id)
  AND (SELECT outcome = 'transfer' AND completed_at IS NOT NULL
       FROM probability_backfill_replays WHERE raw_post_id = :transfer_raw_id)
  AND (SELECT probability_status = 'shadow_scored'
       FROM transfer_reports WHERE dedupe_key = 'backfill-player|old-fc|new-fc'));
SELECT pg_temp.assert_true('legacy probability status default is wrong',
  NOT EXISTS (SELECT 1 FROM transfer_reports WHERE probability_status <> 'legacy_unscored'
    AND dedupe_key <> 'backfill-player|old-fc|new-fc'));
SELECT pg_temp.assert_true('shadow backfill changed material/delivery state',
  (SELECT count(*) FROM transfer_report_revisions) = (SELECT revisions FROM before_material)
  AND (SELECT count(*) FROM digest_items) = (SELECT items FROM before_material)
  AND (SELECT count(*) FROM digest_deliveries) = (SELECT deliveries FROM before_material)
  AND (SELECT coalesce(jsonb_agg(request_payload ORDER BY id), '[]'::jsonb) FROM digest_deliveries)
    = (SELECT payloads FROM before_material));

SELECT complete_probability_backfill(
  :transfer_raw_id, 'qwen-evidence-v1', 'run-a', '2026-08-27 12:00:00+00',
  (SELECT result_payload FROM probability_backfill_replays WHERE raw_post_id = :transfer_raw_id)
);
SELECT pg_temp.assert_true('identical completion was not idempotent',
  (SELECT count(*) FROM probability_backfill_replays) = (SELECT replay_count FROM idempotency_before)
  AND (SELECT count(*) FROM transfer_evidence) = (SELECT evidence_count FROM idempotency_before)
  AND (SELECT count(*) FROM transfer_probability_revisions) = (SELECT probability_count FROM idempotency_before)
  AND (SELECT coalesce(sum(version_counter), 0) FROM transfer_cases) = (SELECT version_count FROM idempotency_before));

UPDATE probability_backfill_replays
SET lease_expires_at = CURRENT_TIMESTAMP - interval '1 second'
WHERE completed_at IS NULL;
CREATE TEMPORARY TABLE retry_claim AS
SELECT * FROM claim_probability_backfill(
  'shadow', '2026-08-27 12:00:00+00', 'run-c', 'qwen-evidence-v1', 100, interval '15 minutes'
);
SELECT pg_temp.assert_true('expired claims were not retryable or completed claims replayed',
  (SELECT count(*) = 100 FROM retry_claim)
  AND NOT EXISTS (SELECT 1 FROM retry_claim WHERE raw_post_id IN (:transfer_raw_id, :ignored_raw_id)));

CREATE TEMPORARY TABLE audit_snapshot AS
SELECT audit FROM probability_backfill_audit('run-a', 'qwen-evidence-v1');
SELECT pg_temp.assert_true('audit output is missing deterministic distributions/sample',
  (SELECT audit ? 'stage_counts' AND audit ? 'probability_buckets' AND audit ? 'post_counts'
      AND audit ? 'review_sample'
      AND audit #>> '{stage_counts,advanced}' = '1'
      AND audit #>> '{post_counts,completed}' = '2'
      AND audit #>> '{post_counts,non_transfer}' = '1'
      AND jsonb_array_length(audit->'review_sample') = 1
      AND audit #>> '{review_sample,0,raw_post_id}' = :'transfer_raw_id'
   FROM audit_snapshot)
  AND (SELECT audit FROM probability_backfill_audit('run-a', 'qwen-evidence-v1'))
    = (SELECT audit FROM audit_snapshot));

ROLLBACK;

SELECT 'probability backfill tests passed' AS result;
