-- Rename extraction identifiers after the local Qwen model was replaced by
-- 9Router Gemini. New code writes 'llm_extract' and 'llm-evidence-v1'; this
-- migration rewrites in-flight rows so backfill claims are not stranded.
-- Immutable audit payload interiors are left untouched: they record what the
-- model actually returned at the time.

UPDATE failures
SET operation_name = 'llm_extract'
WHERE operation_name = 'qwen_extract';

UPDATE retry_states
SET operation_name = 'llm_extract'
WHERE operation_name = 'qwen_extract';

UPDATE probability_backfill_replays
SET extraction_schema_version = 'llm-evidence-v1'
WHERE extraction_schema_version = 'qwen-evidence-v1';

UPDATE probability_backfill_claim_attempts
SET extraction_schema_version = 'llm-evidence-v1'
WHERE extraction_schema_version = 'qwen-evidence-v1';

UPDATE transfer_report_sources
SET extracted_data = jsonb_set(
  extracted_data,
  '{extraction_schema_version}',
  '"llm-evidence-v1"'
)
WHERE extracted_data->>'extraction_schema_version' = 'qwen-evidence-v1';

CREATE OR REPLACE FUNCTION claim_probability_backfill(
  requested_mode text,
  requested_evaluation_time timestamptz,
  requested_run_key text,
  requested_schema_version text DEFAULT 'llm-evidence-v1',
  requested_limit integer DEFAULT 100,
  requested_lease interval DEFAULT interval '15 minutes'
)
RETURNS TABLE (
  claim_ordinal bigint,
  raw_post_id bigint,
  external_post_id text,
  post_url text,
  content text,
  posted_at timestamptz,
  evaluation_time timestamptz,
  external_account_id text,
  username text,
  display_name text,
  priority_rank smallint,
  reliability_score numeric,
  seed_reliability numeric,
  publisher_group_key text,
  source_kind text,
  is_aggregator boolean,
  is_official boolean
)
LANGUAGE plpgsql
AS $$
BEGIN
  IF requested_mode IS DISTINCT FROM 'shadow' THEN
    RETURN;
  END IF;
  IF requested_limit < 1 OR requested_limit > 100 THEN
    RAISE EXCEPTION 'probability backfill limit must be between 1 and 100';
  END IF;
  IF requested_lease <= interval '0 seconds' OR requested_lease > interval '1 hour' THEN
    RAISE EXCEPTION 'probability backfill lease must be between 0 and 1 hour';
  END IF;

  RETURN QUERY
  WITH candidates AS (
    SELECT post.id
    FROM raw_posts post
    LEFT JOIN probability_backfill_replays replay
      ON replay.raw_post_id = post.id
     AND replay.extraction_schema_version = requested_schema_version
    WHERE post.posted_at >= requested_evaluation_time - interval '30 days'
      AND post.posted_at <= requested_evaluation_time
      AND (replay.raw_post_id IS NULL
        OR (replay.completed_at IS NULL AND replay.lease_expires_at <= CURRENT_TIMESTAMP))
    ORDER BY post.posted_at, post.id
    LIMIT requested_limit
    FOR UPDATE OF post SKIP LOCKED
  ), claimed AS (
    INSERT INTO probability_backfill_replays (
      raw_post_id, extraction_schema_version, claimed_run_key, evaluation_time,
      claimed_at, lease_expires_at, attempt_count, completed_at, outcome,
      result_payload, last_error, updated_at
    )
    SELECT candidate.id, requested_schema_version, requested_run_key,
      requested_evaluation_time, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + requested_lease,
      1, NULL, NULL, NULL, NULL, CURRENT_TIMESTAMP
    FROM candidates candidate
    ON CONFLICT ON CONSTRAINT probability_backfill_replays_pkey DO UPDATE
    SET claimed_run_key = EXCLUDED.claimed_run_key,
        evaluation_time = EXCLUDED.evaluation_time,
        claimed_at = EXCLUDED.claimed_at,
        lease_expires_at = EXCLUDED.lease_expires_at,
        attempt_count = probability_backfill_replays.attempt_count + 1,
        last_error = NULL,
        updated_at = CURRENT_TIMESTAMP
    WHERE probability_backfill_replays.completed_at IS NULL
      AND probability_backfill_replays.lease_expires_at <= CURRENT_TIMESTAMP
    RETURNING probability_backfill_replays.raw_post_id,
      probability_backfill_replays.extraction_schema_version,
      probability_backfill_replays.claimed_run_key,
      probability_backfill_replays.evaluation_time,
      probability_backfill_replays.claimed_at,
      probability_backfill_replays.lease_expires_at
  ), attempts AS (
    INSERT INTO probability_backfill_claim_attempts (
      raw_post_id, extraction_schema_version, run_key, evaluation_time,
      claimed_at, lease_expires_at
    )
    SELECT claimed.raw_post_id, claimed.extraction_schema_version, claimed.claimed_run_key,
      claimed.evaluation_time, claimed.claimed_at, claimed.lease_expires_at
    FROM claimed
    ON CONFLICT ON CONSTRAINT probability_backfill_claim_attempts_pkey DO NOTHING
    RETURNING probability_backfill_claim_attempts.raw_post_id
  )
  SELECT row_number() OVER (ORDER BY post.posted_at, post.id),
    post.id, post.external_post_id, post.post_url, post.content, post.posted_at,
    requested_evaluation_time, source.external_account_id, source.username,
    source.display_name, source.priority_rank, source.reliability_score,
    source.seed_reliability, source.publisher_group_key, source.source_kind,
    source.is_aggregator, source.is_official
  FROM claimed
  JOIN raw_posts post ON post.id = claimed.raw_post_id
  JOIN source_accounts source ON source.id = post.source_account_id
  CROSS JOIN (SELECT count(*) FROM attempts) inserted_attempts
  ORDER BY post.posted_at, post.id;
END;
$$;

CREATE OR REPLACE FUNCTION probability_backfill_audit(
  requested_run_key text,
  requested_schema_version text DEFAULT 'llm-evidence-v1'
)
RETURNS TABLE (audit jsonb)
LANGUAGE sql
STABLE
AS $$
  WITH run_replays AS (
    SELECT raw_post_id, completed_at, outcome, audit_reports
    FROM probability_backfill_claim_attempts
    WHERE run_key = requested_run_key
      AND extraction_schema_version = requested_schema_version
  ), scored AS (
    SELECT replay.raw_post_id, (snapshot->>'report_id')::bigint AS report_id,
      snapshot->>'stage' AS transfer_stage,
      (snapshot->>'probability')::numeric AS normalized_probability,
      snapshot->'explanation' AS probability_explanation,
      CASE
        WHEN snapshot->>'probability' IS NULL THEN 'unscored'
        WHEN (snapshot->>'probability')::numeric < 0.25 THEN '00-24'
        WHEN (snapshot->>'probability')::numeric < 0.50 THEN '25-49'
        WHEN (snapshot->>'probability')::numeric < 0.75 THEN '50-74'
        ELSE '75-100'
      END AS probability_bucket
    FROM run_replays replay
    CROSS JOIN LATERAL jsonb_array_elements(replay.audit_reports) snapshot
  ), sample AS (
    SELECT *, row_number() OVER (
      PARTITION BY transfer_stage, probability_bucket ORDER BY raw_post_id, report_id
    ) AS stratum_rank
    FROM scored
  )
  SELECT jsonb_build_object(
    'stage_counts', COALESCE((SELECT jsonb_object_agg(stage, count) FROM (
      SELECT COALESCE(transfer_stage, 'unscored') AS stage, count(*) FROM scored
      GROUP BY COALESCE(transfer_stage, 'unscored') ORDER BY 1
    ) rows), '{}'::jsonb),
    'probability_buckets', COALESCE((SELECT jsonb_object_agg(probability_bucket, count) FROM (
      SELECT probability_bucket, count(*) FROM scored GROUP BY probability_bucket ORDER BY 1
    ) rows), '{}'::jsonb),
    'post_counts', jsonb_build_object(
      'completed', (SELECT count(*) FROM run_replays WHERE completed_at IS NOT NULL),
      'non_transfer', (SELECT count(*) FROM run_replays WHERE outcome = 'non_transfer'),
      'failed_or_retryable', (SELECT count(*) FROM run_replays WHERE completed_at IS NULL)
    ),
    'review_sample', COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'raw_post_id', raw_post_id::text, 'report_id', report_id::text,
      'stage', transfer_stage, 'probability', normalized_probability,
      'probability_bucket', probability_bucket, 'explanation', probability_explanation
    ) ORDER BY COALESCE(transfer_stage, ''), probability_bucket, raw_post_id, report_id)
    FROM sample WHERE stratum_rank = 1), '[]'::jsonb)
  );
$$;
