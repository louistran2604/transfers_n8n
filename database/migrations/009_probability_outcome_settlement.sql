ALTER TABLE source_claim_outcomes
  ADD COLUMN settlement_basis text CHECK (settlement_basis IS NULL OR settlement_basis IN (
    'official_completion', 'authoritative_collapse', 'window_expiry'
  ));

DO $$
DECLARE constraint_name text;
BEGIN
  SELECT conname INTO constraint_name
  FROM pg_constraint
  WHERE conrelid = 'source_claim_outcomes'::regclass
    AND contype = 'c'
    AND pg_get_constraintdef(oid) LIKE '%authoritative_raw_post_id IS NOT NULL%';
  IF constraint_name IS NOT NULL THEN
    EXECUTE format('ALTER TABLE source_claim_outcomes DROP CONSTRAINT %I', constraint_name);
  END IF;
END;
$$;

ALTER TABLE source_claim_outcomes
  ADD CONSTRAINT source_claim_outcomes_settlement_check CHECK (
    (settlement_outcome IS NULL
      AND settlement_basis IS NULL
      AND authoritative_raw_post_id IS NULL
      AND authoritative_transfer_report_revision_id IS NULL
      AND settled_at IS NULL)
    OR
    (settlement_outcome IS NOT NULL
      AND settlement_basis IN ('official_completion', 'authoritative_collapse')
      AND settled_at IS NOT NULL
      AND (authoritative_raw_post_id IS NOT NULL
        OR authoritative_transfer_report_revision_id IS NOT NULL))
    OR
    (settlement_outcome = 'failure'
      AND settlement_basis = 'window_expiry'
      AND settled_at IS NOT NULL
      AND authoritative_raw_post_id IS NULL
      AND authoritative_transfer_report_revision_id IS NULL)
  );

CREATE INDEX source_claim_outcomes_pending_case_idx
  ON source_claim_outcomes (transfer_case_id, transfer_report_id)
  WHERE settlement_outcome IS NULL;

CREATE FUNCTION probability_v1_register_claims(
  requested_transfer_case_id bigint,
  requested_evaluated_at timestamptz
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE changed_count integer;
BEGIN
  WITH resolved AS (
    SELECT evidence.transfer_report_id, evidence.stage_signal,
      evidence.club_agreement_state, evidence.personal_terms_state,
      evidence.completion_claim, post.posted_at,
      COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,account_id}', '')::bigint,
        originator.id,
        CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.id END
      ) AS source_account_id,
      COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,source_kind}',
        originator.source_kind,
        CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.source_kind END
      ) AS source_kind,
      CASE
        WHEN evidence.completion_claim = 'reporter_done' OR evidence.stage_signal = 'done'
          THEN 'done'
        WHEN evidence.stage_signal = 'agreed'
          OR evidence.club_agreement_state IN ('agreed', 'not_applicable')
          OR evidence.personal_terms_state = 'agreed' THEN 'agreed'
        WHEN evidence.stage_signal = 'advanced' THEN 'advanced'
      END AS eligible_stage,
      CASE
        WHEN evidence.completion_claim = 'reporter_done' OR evidence.stage_signal = 'done'
          THEN 1.00::numeric
        WHEN evidence.stage_signal = 'agreed'
          OR evidence.club_agreement_state IN ('agreed', 'not_applicable')
          OR evidence.personal_terms_state = 'agreed' THEN 0.75::numeric
        WHEN evidence.stage_signal = 'advanced' THEN 0.50::numeric
      END AS eligible_weight
    FROM transfer_evidence evidence
    JOIN raw_posts post ON post.id = evidence.raw_post_id
    JOIN source_accounts posting ON posting.id = post.source_account_id
    LEFT JOIN LATERAL (
      SELECT account.* FROM source_accounts account
      WHERE evidence.named_originator IS NOT NULL
        AND lower(account.username) = lower(regexp_replace(evidence.named_originator, '^@', ''))
        AND account.is_active
      ORDER BY account.id LIMIT 1
    ) originator ON true
    WHERE evidence.transfer_case_id = requested_transfer_case_id
      AND evidence.claim_stance = 'supports'
      AND evidence.completion_claim <> 'official_announcement'
      AND evidence.extraction_confidence >= 0.50
      AND post.posted_at <= requested_evaluated_at
  ), eligible AS (
    SELECT source_account_id, transfer_report_id,
      (array_agg(eligible_stage ORDER BY posted_at, eligible_weight, transfer_report_id))[1]
        AS first_eligible_stage,
      min(posted_at) AS claimed_at,
      max(eligible_weight) AS outcome_weight
    FROM resolved
    WHERE eligible_stage IS NOT NULL
      AND source_account_id IS NOT NULL
      AND source_kind IN ('journalist', 'publisher')
    GROUP BY source_account_id, transfer_report_id
  ), changed AS (
    INSERT INTO source_claim_outcomes (
      source_account_id, transfer_case_id, transfer_report_id,
      first_eligible_stage, claimed_at, outcome_weight
    )
    SELECT source_account_id, requested_transfer_case_id, transfer_report_id,
      first_eligible_stage, claimed_at, outcome_weight
    FROM eligible
    ON CONFLICT (source_account_id, transfer_case_id, transfer_report_id) DO UPDATE
    SET outcome_weight = EXCLUDED.outcome_weight
    WHERE source_claim_outcomes.settlement_outcome IS NULL
      AND source_claim_outcomes.outcome_weight < EXCLUDED.outcome_weight
    RETURNING 1
  )
  SELECT count(*) INTO changed_count FROM changed;
  RETURN changed_count;
END;
$$;

CREATE FUNCTION probability_v1_append_reliability_snapshots(
  requested_source_account_ids bigint[],
  requested_calculated_at timestamptz
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE inserted_count integer;
BEGIN
  WITH posterior AS (
    SELECT source.id AS source_account_id,
      (8 * COALESCE(source.seed_reliability, source.reliability_score, 0.70)
        + COALESCE(sum(outcome.outcome_weight)
          FILTER (WHERE outcome.settlement_outcome = 'success'), 0))::numeric AS alpha,
      (8 * (1 - COALESCE(source.seed_reliability, source.reliability_score, 0.70))
        + COALESCE(sum(outcome.outcome_weight)
          FILTER (WHERE outcome.settlement_outcome = 'failure'), 0))::numeric AS beta,
      COALESCE(sum(outcome.outcome_weight)
        FILTER (WHERE outcome.settlement_outcome IS NOT NULL), 0)::numeric AS resolved_count
    FROM source_accounts source
    LEFT JOIN source_claim_outcomes outcome ON outcome.source_account_id = source.id
      AND outcome.settlement_basis IS NOT NULL
    WHERE source.id = ANY(requested_source_account_ids)
    GROUP BY source.id, source.seed_reliability, source.reliability_score
  ), inserted AS (
    INSERT INTO source_reliability_snapshots (
      source_account_id, engine_version, alpha, beta, effective_resolved_count,
      posterior_reliability, calculated_at
    )
    SELECT source_account_id, 'probability-v1', alpha, beta, resolved_count,
      GREATEST(0.55, LEAST(0.95, alpha / (alpha + beta))), requested_calculated_at
    FROM posterior
    ON CONFLICT (source_account_id, engine_version, calculated_at) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO inserted_count FROM inserted;
  RETURN inserted_count;
END;
$$;

CREATE FUNCTION probability_v1_settle_authoritative_claims(
  requested_transfer_case_id bigint,
  requested_evaluated_at timestamptz
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE authoritative record; changed_count integer; changed_sources bigint[];
BEGIN
  SELECT evidence.transfer_report_id, evidence.raw_post_id, post.posted_at,
    CASE WHEN evidence.completion_claim = 'official_announcement'
      THEN 'official_completion' ELSE 'authoritative_collapse' END AS basis
  INTO authoritative
  FROM transfer_evidence evidence
  JOIN raw_posts post ON post.id = evidence.raw_post_id
  JOIN source_accounts posting ON posting.id = post.source_account_id
  WHERE evidence.transfer_case_id = requested_transfer_case_id
    AND evidence.extraction_confidence >= 0.50
    AND post.posted_at <= requested_evaluated_at
    AND COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,source_kind}',
      posting.source_kind) IN ('club_official', 'league_official')
    AND (evidence.completion_claim = 'official_announcement'
      OR evidence.stage_signal = 'collapsed'
      OR evidence.club_agreement_state = 'collapsed')
  ORDER BY (evidence.completion_claim = 'official_announcement') DESC,
    post.posted_at DESC, evidence.raw_post_id DESC, evidence.id DESC
  LIMIT 1;

  IF authoritative.raw_post_id IS NULL THEN RETURN 0; END IF;

  PERFORM 1 FROM source_accounts source
  WHERE source.id IN (SELECT source_account_id FROM source_claim_outcomes
    WHERE transfer_case_id = requested_transfer_case_id)
  ORDER BY source.id FOR UPDATE;

  WITH changed AS (
    UPDATE source_claim_outcomes outcome
    SET settlement_outcome = CASE
          WHEN authoritative.basis = 'official_completion'
            AND outcome.transfer_report_id = authoritative.transfer_report_id THEN 'success'
          ELSE 'failure'
        END,
        settlement_basis = authoritative.basis,
        authoritative_raw_post_id = authoritative.raw_post_id,
        authoritative_transfer_report_revision_id = NULL,
        settled_at = requested_evaluated_at
    WHERE outcome.transfer_case_id = requested_transfer_case_id
      AND (
        (authoritative.basis = 'official_completion'
          AND (outcome.settlement_outcome IS NULL
            OR outcome.settlement_basis = 'authoritative_collapse'))
        OR
        (authoritative.basis = 'authoritative_collapse'
          AND outcome.transfer_report_id = authoritative.transfer_report_id
          AND outcome.settlement_outcome IS NULL)
      )
    RETURNING source_account_id
  )
  SELECT count(*), array_agg(DISTINCT source_account_id)
  INTO changed_count, changed_sources FROM changed;

  IF changed_count > 0 THEN
    PERFORM probability_v1_append_reliability_snapshots(
      changed_sources, requested_evaluated_at);
  END IF;
  RETURN changed_count;
END;
$$;

CREATE FUNCTION probability_v1_process_case_outcomes(
  requested_transfer_case_id bigint,
  requested_evaluated_at timestamptz
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE registered integer; settled integer;
BEGIN
  registered := probability_v1_register_claims(
    requested_transfer_case_id, requested_evaluated_at);
  settled := probability_v1_settle_authoritative_claims(
    requested_transfer_case_id, requested_evaluated_at);
  RETURN registered + settled;
END;
$$;

CREATE FUNCTION probability_v1_window_expiry_at(requested_window_key text)
RETURNS timestamptz
LANGUAGE plpgsql
IMMUTABLE
PARALLEL SAFE
AS $$
DECLARE requested_year integer;
BEGIN
  IF requested_window_key !~ '^[0-9]{4}-H[12]$' THEN
    RAISE EXCEPTION 'invalid transfer window key %', requested_window_key;
  END IF;
  requested_year := left(requested_window_key, 4)::integer;
  IF right(requested_window_key, 2) = 'H1' THEN
    RETURN make_timestamptz(requested_year, 7, 15, 0, 0, 0, 'UTC');
  END IF;
  RETURN make_timestamptz(requested_year + 1, 1, 15, 0, 0, 0, 'UTC');
END;
$$;

CREATE FUNCTION settle_expired_probability_v1_cases(
  requested_mode text,
  requested_evaluated_at timestamptz,
  requested_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE selected_case record; changed_sources bigint[];
  all_changed_sources bigint[] := '{}'::bigint[]; processed integer := 0;
BEGIN
  IF requested_mode NOT IN ('shadow', 'active') THEN RETURN 0; END IF;

  FOR selected_case IN
    SELECT transfer_case.id
    FROM transfer_cases transfer_case
    WHERE transfer_case.status IN ('open', 'collapsed')
      AND requested_evaluated_at >= probability_v1_window_expiry_at(
        transfer_case.transfer_window_key)
      AND EXISTS (SELECT 1 FROM source_claim_outcomes outcome
        WHERE outcome.transfer_case_id = transfer_case.id
          AND outcome.settlement_outcome IS NULL)
    ORDER BY transfer_case.id
    FOR UPDATE OF transfer_case SKIP LOCKED
    LIMIT LEAST(GREATEST(requested_limit, 0), 100)
  LOOP
    PERFORM 1 FROM source_accounts source
    WHERE source.id IN (SELECT source_account_id FROM source_claim_outcomes
      WHERE transfer_case_id = selected_case.id AND settlement_outcome IS NULL)
    ORDER BY source.id FOR UPDATE;

    WITH changed AS (
      UPDATE source_claim_outcomes
      SET settlement_outcome = 'failure', settlement_basis = 'window_expiry',
          settled_at = requested_evaluated_at,
          authoritative_raw_post_id = NULL,
          authoritative_transfer_report_revision_id = NULL
      WHERE transfer_case_id = selected_case.id AND settlement_outcome IS NULL
      RETURNING source_account_id
    )
    SELECT array_agg(DISTINCT source_account_id) INTO changed_sources FROM changed;

    IF changed_sources IS NOT NULL THEN
      SELECT array_agg(DISTINCT source_account_id)
      INTO all_changed_sources
      FROM unnest(all_changed_sources || changed_sources) source_account_id;
      UPDATE transfer_cases SET status = 'closed' WHERE id = selected_case.id;
      processed := processed + 1;
    END IF;
  END LOOP;
  IF processed > 0 THEN
    PERFORM probability_v1_append_reliability_snapshots(
      all_changed_sources, requested_evaluated_at);
    PERFORM recompute_probability_v1_reporter_cases(
      requested_mode, requested_evaluated_at, NULL, 100);
  END IF;
  RETURN processed;
END;
$$;

CREATE FUNCTION recompute_probability_v1_reporter_cases(
  requested_mode text,
  requested_evaluated_at timestamptz,
  excluded_transfer_case_id bigint DEFAULT NULL,
  requested_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE selected_case record; selected_report_id bigint; payload jsonb; processed integer := 0;
BEGIN
  IF requested_mode NOT IN ('shadow', 'active') THEN RETURN 0; END IF;

  FOR selected_case IN
    SELECT transfer_case.id
    FROM transfer_cases transfer_case
    WHERE transfer_case.status = 'open'
      AND transfer_case.id IS DISTINCT FROM excluded_transfer_case_id
      AND EXISTS (
        SELECT 1
        FROM transfer_reports report
        JOIN transfer_evidence evidence ON evidence.transfer_report_id = report.id
        JOIN source_reliability_snapshots snapshot
          ON snapshot.source_account_id = NULLIF(
            evidence.raw_normalized_extraction #>> '{_resolved_source,account_id}', '')::bigint
         AND snapshot.engine_version = 'probability-v1'
         AND snapshot.calculated_at = requested_evaluated_at
        WHERE report.transfer_case_id = transfer_case.id
          AND report.probability_status IN ('shadow_scored', 'active_scored')
          AND report.probability_updated_at < requested_evaluated_at
      )
    ORDER BY transfer_case.id
    FOR UPDATE OF transfer_case SKIP LOCKED
    LIMIT LEAST(GREATEST(requested_limit, 0), 100)
  LOOP
    SELECT report.id, jsonb_build_object(
      'probability_mode', requested_mode,
      '_skip_reporter_recompute', true,
      'evaluated_at', requested_evaluated_at,
      'destination_club_name', report.destination_club_name,
      'normalized_data', jsonb_build_object(
        'current_club_key', COALESCE(transfer_case.normalized_current_club, 'unknown')),
      'sources', jsonb_build_array(jsonb_build_object(
        'raw_post_id', evidence.raw_post_id,
        'posted_at', post.posted_at,
        'report_ordinal', evidence.report_ordinal,
        'extraction_schema_version', evidence.extraction_schema_version,
        'normalized_evidence', evidence.raw_normalized_extraction - '_resolved_source')))
    INTO selected_report_id, payload
    FROM transfer_reports report
    JOIN transfer_cases transfer_case ON transfer_case.id = report.transfer_case_id
    JOIN LATERAL (
      SELECT evidence.* FROM transfer_evidence evidence
      WHERE evidence.transfer_report_id = report.id
      ORDER BY evidence.created_at, evidence.id LIMIT 1
    ) evidence ON true
    JOIN raw_posts post ON post.id = evidence.raw_post_id
    WHERE report.transfer_case_id = selected_case.id
    ORDER BY report.id LIMIT 1;

    IF requested_mode = 'active' THEN
      PERFORM apply_probability_v1_active(selected_report_id, payload);
    ELSE
      PERFORM apply_probability_v1_shadow(selected_report_id, payload);
    END IF;
    processed := processed + 1;
  END LOOP;
  RETURN processed;
END;
$$;

ALTER FUNCTION apply_probability_v1_shadow(bigint, jsonb)
  RENAME TO apply_probability_v1_shadow_core;

CREATE FUNCTION apply_probability_v1_shadow(
  requested_transfer_report_id bigint,
  payload jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE probability_revision_id bigint; requested_transfer_case_id bigint;
  outcome_change_count integer;
BEGIN
  IF payload->>'probability_mode' IS DISTINCT FROM 'shadow' THEN RETURN NULL; END IF;

  probability_revision_id := apply_probability_v1_shadow_core(
    requested_transfer_report_id, payload);
  SELECT transfer_case_id INTO requested_transfer_case_id
  FROM transfer_reports WHERE id = requested_transfer_report_id;
  IF requested_transfer_case_id IS NULL THEN RETURN probability_revision_id; END IF;

  outcome_change_count := probability_v1_process_case_outcomes(
    requested_transfer_case_id, (payload->>'evaluated_at')::timestamptz);
  IF outcome_change_count > 0 THEN
    probability_revision_id := apply_probability_v1_shadow_core(
      requested_transfer_report_id, payload);
  END IF;
  IF COALESCE((payload->>'_skip_reporter_recompute')::boolean, false) = false THEN
    PERFORM recompute_probability_v1_reporter_cases(
      COALESCE(payload->>'_settlement_mode', 'shadow'),
      (payload->>'evaluated_at')::timestamptz,
      requested_transfer_case_id,
      100);
  END IF;
  RETURN probability_revision_id;
END;
$$;

CREATE OR REPLACE FUNCTION apply_probability_v1_active(
  requested_transfer_report_id bigint,
  payload jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE probability_revision_id bigint; requested_transfer_case_id bigint;
BEGIN
  IF payload->>'probability_mode' IS DISTINCT FROM 'active' THEN RETURN NULL; END IF;

  probability_revision_id := apply_probability_v1_shadow(
    requested_transfer_report_id,
    jsonb_set(payload, '{probability_mode}', '"shadow"'::jsonb)
      || jsonb_build_object('_settlement_mode', 'active')
  );
  SELECT transfer_case_id INTO requested_transfer_case_id
  FROM transfer_reports WHERE id = requested_transfer_report_id;
  PERFORM promote_probability_v1_case(
    requested_transfer_case_id, (payload->>'evaluated_at')::timestamptz);
  UPDATE transfer_reports
  SET probability_status = 'active_scored'
  WHERE transfer_case_id = requested_transfer_case_id
    AND probability_engine_version = 'probability-v1'
    AND normalized_probability IS NOT NULL;
  RETURN probability_revision_id;
END;
$$;
