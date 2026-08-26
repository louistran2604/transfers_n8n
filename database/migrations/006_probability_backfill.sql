ALTER TABLE transfer_reports
  ADD COLUMN probability_status text NOT NULL DEFAULT 'legacy_unscored'
    CHECK (probability_status IN ('legacy_unscored', 'shadow_scored'));

CREATE FUNCTION app_set_probability_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF NEW.probability_engine_version = 'probability-v1'
      AND NEW.normalized_probability IS NOT NULL THEN
    NEW.probability_status := 'shadow_scored';
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER transfer_reports_set_probability_status
  BEFORE UPDATE OF probability_engine_version, normalized_probability ON transfer_reports
  FOR EACH ROW EXECUTE FUNCTION app_set_probability_status();

CREATE TABLE probability_backfill_replays (
  raw_post_id bigint NOT NULL REFERENCES raw_posts (id) ON DELETE RESTRICT,
  extraction_schema_version text NOT NULL CHECK (btrim(extraction_schema_version) <> ''),
  claimed_run_key text NOT NULL CHECK (btrim(claimed_run_key) <> ''),
  evaluation_time timestamptz NOT NULL,
  claimed_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  lease_expires_at timestamptz NOT NULL,
  attempt_count integer NOT NULL DEFAULT 1 CHECK (attempt_count > 0),
  completed_at timestamptz,
  outcome text CHECK (outcome IN ('transfer', 'non_transfer')),
  result_payload jsonb CHECK (result_payload IS NULL OR jsonb_typeof(result_payload) = 'array'),
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (raw_post_id, extraction_schema_version),
  CHECK ((completed_at IS NULL AND outcome IS NULL) OR (completed_at IS NOT NULL AND outcome IS NOT NULL))
);

CREATE INDEX probability_backfill_replays_retry_idx
  ON probability_backfill_replays (lease_expires_at, raw_post_id)
  WHERE completed_at IS NULL;

CREATE FUNCTION claim_probability_backfill(
  requested_mode text,
  requested_evaluation_time timestamptz,
  requested_run_key text,
  requested_schema_version text DEFAULT 'qwen-evidence-v1',
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
    RETURNING probability_backfill_replays.raw_post_id
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
  ORDER BY post.posted_at, post.id;
END;
$$;

CREATE FUNCTION fail_probability_backfill_claim(
  requested_raw_post_id bigint,
  requested_schema_version text,
  requested_run_key text,
  requested_error text
)
RETURNS bigint
LANGUAGE sql
AS $$
  UPDATE probability_backfill_replays
  SET lease_expires_at = CURRENT_TIMESTAMP,
      last_error = requested_error,
      updated_at = CURRENT_TIMESTAMP
  WHERE raw_post_id = requested_raw_post_id
    AND extraction_schema_version = requested_schema_version
    AND claimed_run_key = requested_run_key
    AND completed_at IS NULL
  RETURNING raw_post_id;
$$;

CREATE FUNCTION complete_probability_backfill(
  requested_raw_post_id bigint,
  requested_schema_version text,
  requested_run_key text,
  requested_evaluation_time timestamptz,
  requested_reports jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  replay probability_backfill_replays%ROWTYPE;
  payload jsonb;
  player_id bigint;
  report_id bigint;
BEGIN
  IF jsonb_typeof(requested_reports) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'backfill reports must be a JSON array';
  END IF;

  SELECT * INTO replay
  FROM probability_backfill_replays
  WHERE raw_post_id = requested_raw_post_id
    AND extraction_schema_version = requested_schema_version
  FOR UPDATE;
  IF replay.completed_at IS NOT NULL THEN
    RETURN replay.raw_post_id;
  END IF;
  IF replay.raw_post_id IS NULL OR replay.claimed_run_key IS DISTINCT FROM requested_run_key
      OR replay.evaluation_time IS DISTINCT FROM requested_evaluation_time THEN
    RAISE EXCEPTION 'backfill claim is missing, expired, or owned by another run';
  END IF;

  FOR payload IN SELECT value FROM jsonb_array_elements(requested_reports)
  LOOP
    IF payload->>'probability_mode' IS DISTINCT FROM 'shadow'
        OR (payload->>'evaluated_at')::timestamptz IS DISTINCT FROM requested_evaluation_time
        OR jsonb_typeof(payload->'sources') IS DISTINCT FROM 'array'
        OR jsonb_array_length(payload->'sources') <> 1
        OR (payload #>> '{sources,0,raw_post_id}')::bigint <> requested_raw_post_id
        OR payload #>> '{sources,0,extraction_schema_version}' IS DISTINCT FROM requested_schema_version THEN
      RAISE EXCEPTION 'backfill report does not match its shadow claim';
    END IF;

    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES (payload->>'player_identity_key', payload->>'player_name', payload->>'normalized_player_name')
    ON CONFLICT (identity_key) DO NOTHING
    RETURNING id INTO player_id;
    IF player_id IS NULL THEN
      SELECT id INTO player_id FROM players WHERE identity_key = payload->>'player_identity_key';
    END IF;

    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name,
      destination_club_name, classification, move_type, fee_amount, fee_currency,
      add_ons_amount, add_ons_currency, release_clause_amount, release_clause_currency,
      contract_length_months, contract_expires_on, loan_ends_on,
      has_option_to_buy, has_obligation_to_buy, sell_on_percentage, medical_status,
      agreement_status, confidence, first_reported_at, last_reported_at, normalized_data
    ) VALUES (
      payload->>'dedupe_key', player_id, payload->>'player_name',
      NULLIF(payload->>'current_club_name', ''), NULLIF(payload->>'destination_club_name', ''),
      payload->>'classification', COALESCE(payload->>'move_type', 'unknown'),
      NULLIF(payload->>'fee_amount', '')::numeric, NULLIF(payload->>'fee_currency', ''),
      NULLIF(payload->>'add_ons_amount', '')::numeric, NULLIF(payload->>'add_ons_currency', ''),
      NULLIF(payload->>'release_clause_amount', '')::numeric, NULLIF(payload->>'release_clause_currency', ''),
      NULLIF(payload->>'contract_length_months', '')::integer,
      NULLIF(payload->>'contract_expires_on', '')::date, NULLIF(payload->>'loan_ends_on', '')::date,
      NULLIF(payload->>'has_option_to_buy', '')::boolean,
      NULLIF(payload->>'has_obligation_to_buy', '')::boolean,
      NULLIF(payload->>'sell_on_percentage', '')::numeric,
      payload->>'medical_status', payload->>'agreement_status',
      (payload->>'extraction_confidence')::numeric,
      (payload->>'first_reported_at')::timestamptz,
      (payload->>'last_reported_at')::timestamptz,
      COALESCE(payload->'normalized_data', '{}'::jsonb)
    )
    ON CONFLICT (dedupe_key) DO NOTHING
    RETURNING id INTO report_id;
    IF report_id IS NULL THEN
      SELECT id INTO report_id FROM transfer_reports WHERE dedupe_key = payload->>'dedupe_key';
    END IF;

    PERFORM apply_probability_v1_shadow(report_id, payload);
  END LOOP;

  UPDATE probability_backfill_replays
  SET completed_at = CURRENT_TIMESTAMP,
      outcome = CASE WHEN jsonb_array_length(requested_reports) = 0 THEN 'non_transfer' ELSE 'transfer' END,
      result_payload = requested_reports,
      lease_expires_at = CURRENT_TIMESTAMP,
      last_error = NULL,
      updated_at = CURRENT_TIMESTAMP
  WHERE raw_post_id = requested_raw_post_id
    AND extraction_schema_version = requested_schema_version
  RETURNING probability_backfill_replays.raw_post_id INTO requested_raw_post_id;
  RETURN requested_raw_post_id;
END;
$$;

CREATE FUNCTION probability_backfill_audit(
  requested_run_key text,
  requested_schema_version text DEFAULT 'qwen-evidence-v1'
)
RETURNS TABLE (audit jsonb)
LANGUAGE sql
STABLE
AS $$
  WITH run_replays AS (
    SELECT * FROM probability_backfill_replays
    WHERE claimed_run_key = requested_run_key
      AND extraction_schema_version = requested_schema_version
  ), scored AS (
    SELECT DISTINCT replay.raw_post_id, report.id AS report_id,
      evidence.stage_signal AS transfer_stage,
      revision.normalized_probability, revision.explanation AS probability_explanation,
      CASE
        WHEN revision.normalized_probability IS NULL THEN 'unscored'
        WHEN revision.normalized_probability < 0.25 THEN '00-24'
        WHEN revision.normalized_probability < 0.50 THEN '25-49'
        WHEN revision.normalized_probability < 0.75 THEN '50-74'
        ELSE '75-100'
      END AS probability_bucket
    FROM run_replays replay
    JOIN transfer_evidence evidence ON evidence.raw_post_id = replay.raw_post_id
      AND evidence.extraction_schema_version = replay.extraction_schema_version
    JOIN transfer_reports report ON report.id = evidence.transfer_report_id
    LEFT JOIN LATERAL (
      SELECT scored_revision.normalized_probability, scored_revision.explanation
      FROM transfer_probability_revisions scored_revision
      WHERE scored_revision.transfer_report_id = report.id
        AND scored_revision.evaluated_at = replay.evaluation_time
      ORDER BY scored_revision.revision_number DESC, scored_revision.id DESC
      LIMIT 1
    ) revision ON true
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
