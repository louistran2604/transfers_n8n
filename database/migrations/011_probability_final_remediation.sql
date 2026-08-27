CREATE OR REPLACE FUNCTION score_transfer_probability_v1(
  requested_transfer_report_id bigint,
  requested_evaluated_at timestamptz
)
RETURNS TABLE (
  raw_probability numeric,
  normalized_probability numeric,
  current_stage text,
  explanation jsonb,
  input_fingerprint text
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
WITH base AS MATERIALIZED (
  SELECT scored.*
  FROM score_transfer_probability_v1_pre_final_review(
    requested_transfer_report_id, requested_evaluated_at) scored
), resolved AS (
  SELECT evidence.id, evidence.raw_post_id, evidence.destination_club_name,
    evidence.stage_signal, evidence.claim_stance, evidence.wording_strength,
    evidence.club_agreement_state, evidence.personal_terms_state,
    evidence.completion_claim, evidence.attribution_kind, evidence.named_originator,
    evidence.extraction_confidence,
    evidence.resolved_independence_key, evidence.raw_normalized_extraction,
    post.posted_at,
    COALESCE(evidence.resolved_independence_key, CASE
      WHEN originator.id IS NOT NULL THEN COALESCE(originator.publisher_group_key, 'source:' || originator.id)
      WHEN evidence.attribution_kind IN ('original', 'unknown')
        THEN COALESCE(posting.publisher_group_key, 'source:' || posting.id)
      ELSE 'unknown'
    END) AS independence_key,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,account_id}', '')::bigint,
      originator.id,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.id END,
      posting.id) AS resolved_account_id,
    COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,source_kind}',
      originator.source_kind,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.source_kind END
    ) AS resolved_source_kind,
    COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,username}',
      originator.username,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.username END,
      posting.username) AS source_username,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,seed_reliability}', '')::numeric,
      originator.seed_reliability,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.seed_reliability END
    ) AS resolved_seed_reliability,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,reliability_score}', '')::numeric,
      originator.reliability_score,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.reliability_score END
    ) AS resolved_reliability_score,
    GREATEST(0, EXTRACT(epoch FROM (requested_evaluated_at - post.posted_at)) / 86400)::numeric
      AS age_days
  FROM transfer_evidence evidence
  JOIN raw_posts post ON post.id = evidence.raw_post_id
  JOIN source_accounts posting ON posting.id = post.source_account_id
  LEFT JOIN LATERAL (
    SELECT account.*
    FROM source_accounts account
    WHERE evidence.named_originator IS NOT NULL
      AND lower(account.username) = lower(regexp_replace(evidence.named_originator, '^@', ''))
      AND account.is_active
    ORDER BY account.id
    LIMIT 1
  ) originator ON true
  WHERE evidence.transfer_report_id = requested_transfer_report_id
    AND evidence.extraction_confidence >= 0.50
    AND post.posted_at <= requested_evaluated_at
), accepted AS (
  SELECT resolved.*,
    COALESCE(snapshot.posterior_reliability,
      GREATEST(0.55, LEAST(0.95, COALESCE(
        resolved_seed_reliability, resolved_reliability_score, 0.70
      ))))::numeric AS reliability,
    CASE wording_strength
      WHEN 'hedged' THEN 0.75 WHEN 'reported' THEN 0.90
      WHEN 'direct' THEN 1.00 WHEN 'definitive' THEN 1.10
    END::numeric AS wording_factor,
    CASE
      WHEN claim_stance = 'contradicts'
        OR club_agreement_state IN ('rejected', 'collapsed')
        OR personal_terms_state = 'rejected'
        OR stage_signal IN ('setback', 'collapsed') THEN 14
      WHEN stage_signal IN ('link', 'interest') THEN 7
      WHEN stage_signal IN ('agreed', 'done', 'official_wording')
        OR completion_claim <> 'none' THEN 30
      ELSE 14
    END::numeric AS half_life_days
  FROM resolved
  LEFT JOIN LATERAL (
    SELECT reliability.posterior_reliability
    FROM source_reliability_snapshots reliability
    WHERE reliability.source_account_id = resolved.resolved_account_id
      AND reliability.engine_version = 'probability-v1'
      AND reliability.calculated_at <= requested_evaluated_at
    ORDER BY reliability.calculated_at DESC, reliability.id DESC
    LIMIT 1
  ) snapshot ON true
), ranked AS (
  SELECT accepted.*,
    CASE
      WHEN resolved_source_kind IN ('club_official', 'league_official')
        AND (completion_claim = 'official_announcement'
          OR stage_signal = 'collapsed' OR club_agreement_state = 'collapsed') THEN 1::numeric
      ELSE power(2::numeric, -age_days / half_life_days)
    END AS recency_factor,
    row_number() OVER (
      PARTITION BY lower(COALESCE(destination_club_name, '')), independence_key
      ORDER BY posted_at DESC,
        CASE stage_signal
          WHEN 'official_wording' THEN 10 WHEN 'done' THEN 9 WHEN 'collapsed' THEN 8
          WHEN 'agreed' THEN 7 WHEN 'advanced' THEN 6 WHEN 'setback' THEN 5
          WHEN 'talks' THEN 4 WHEN 'interest' THEN 3 WHEN 'link' THEN 2 ELSE 1
        END DESC,
        CASE wording_strength WHEN 'definitive' THEN 4 WHEN 'direct' THEN 3
          WHEN 'reported' THEN 2 ELSE 1 END DESC,
        raw_post_id DESC, id DESC
    ) AS active_rank
  FROM accepted
), official AS (
  SELECT 1 AS present FROM ranked
  WHERE resolved_source_kind IN ('club_official', 'league_official')
    AND completion_claim = 'official_announcement'
  LIMIT 1
), collapse AS (
  SELECT ranked.* FROM ranked
  WHERE resolved_source_kind IN ('club_official', 'league_official')
    AND (stage_signal = 'collapsed' OR club_agreement_state = 'collapsed')
  ORDER BY posted_at DESC, raw_post_id DESC, id DESC LIMIT 1
), later_advanced AS (
  SELECT ranked.* FROM ranked CROSS JOIN collapse
  WHERE ranked.active_rank = 1
    AND NOT EXISTS (SELECT 1 FROM official)
    AND ranked.claim_stance = 'supports'
    AND ranked.posted_at > collapse.posted_at
    AND (ranked.stage_signal IN ('advanced', 'agreed', 'done', 'official_wording')
      OR ranked.completion_claim = 'reporter_done')
  ORDER BY ranked.posted_at DESC, ranked.raw_post_id DESC, ranked.id DESC LIMIT 1
), reopen_values AS (
  SELECT later_advanced.*,
    CASE
      WHEN completion_claim = 'reporter_done' OR stage_signal IN ('done', 'official_wording') THEN 'done'
      WHEN stage_signal = 'agreed' OR club_agreement_state IN ('agreed', 'not_applicable')
        OR personal_terms_state = 'agreed' THEN 'agreed'
      ELSE 'advanced'
    END AS reopen_stage,
    CASE
      WHEN completion_claim = 'reporter_done' OR stage_signal IN ('done', 'official_wording') THEN 0.97::numeric
      WHEN stage_signal = 'agreed' OR club_agreement_state IN ('agreed', 'not_applicable')
        OR personal_terms_state = 'agreed' THEN 0.72::numeric
      ELSE 0.55::numeric
    END AS reopen_base,
    CASE
      WHEN completion_claim = 'reporter_done' OR stage_signal IN ('done', 'official_wording') THEN 0.98::numeric
      WHEN stage_signal = 'agreed' OR club_agreement_state IN ('agreed', 'not_applicable')
        OR personal_terms_state = 'agreed' THEN 0.90::numeric
      ELSE 0.82::numeric
    END AS reopen_ceiling
  FROM later_advanced
), reopen_result AS (
  SELECT reopen_values.*,
    GREATEST(-0.50, LEAST(0.50, 2 * (reliability - 0.75)))
      * wording_factor * recency_factor AS primary_adjustment
  FROM reopen_values
), reopen_output AS (
  SELECT round(LEAST(reopen_ceiling, 1 / (1 + exp(-(
      ln(reopen_base / (1 - reopen_base)) + primary_adjustment)))), 5) AS probability,
    reopen_stage,
    jsonb_build_object(
      'engine_version', 'probability-v1', 'evaluated_at', requested_evaluated_at,
      'stage', jsonb_build_object('name', reopen_stage, 'base', reopen_base, 'ceiling', reopen_ceiling),
      'terminal_kind', NULL,
      'primary', jsonb_build_object('source_account', source_username,
        'independence_key', independence_key, 'reliability', reliability,
        'wording_factor', wording_factor, 'recency_factor', recency_factor,
        'adjustment', primary_adjustment),
      'corroboration', '[]'::jsonb, 'contradictions', '[]'::jsonb,
      'story_staleness_adjustment', 0, 'normalization', 'pending-stage-5'
    ) AS details
  FROM reopen_result
), contradiction_candidates AS (
  SELECT ranked.*,
    CASE
      WHEN club_agreement_state = 'rejected' OR personal_terms_state = 'rejected' THEN -0.80::numeric
      WHEN stage_signal = 'setback' THEN -0.60::numeric
      ELSE -1.60::numeric
    END AS contradiction_base
  FROM ranked
  WHERE active_rank = 1
    AND (club_agreement_state = 'rejected' OR personal_terms_state = 'rejected'
      OR stage_signal = 'setback' OR claim_stance = 'contradicts'
      OR stage_signal = 'collapsed' OR club_agreement_state = 'collapsed')
), contradiction_order AS (
  SELECT contradiction_candidates.*,
    row_number() OVER (ORDER BY
      abs(contradiction_base * GREATEST(0.25, LEAST(1.00, (reliability - 0.50) / 0.45))
        * wording_factor * recency_factor) DESC,
      independence_key, raw_post_id DESC, id DESC) AS contribution_rank
  FROM contradiction_candidates
), contradiction_values AS (
  SELECT contradiction_order.*,
    contradiction_base * GREATEST(0.25, LEAST(1.00, (reliability - 0.50) / 0.45))
      * wording_factor * recency_factor
      * CASE contribution_rank WHEN 1 THEN 1.00 WHEN 2 THEN 0.70
        WHEN 3 THEN 0.50 ELSE 0.25 END AS adjustment
  FROM contradiction_order
), contradiction_output AS (
  SELECT round(LEAST(0.25::numeric, 1 / (1 + exp(-(
      ln(0.10 / 0.90) + COALESCE(sum(adjustment), 0))))), 5) AS probability,
    jsonb_build_object(
      'engine_version', 'probability-v1', 'evaluated_at', requested_evaluated_at,
      'stage', jsonb_build_object('name', 'link', 'base', 0.10, 'ceiling', 0.25),
      'terminal_kind', NULL, 'primary', '{}'::jsonb, 'corroboration', '[]'::jsonb,
      'contradictions', COALESCE(jsonb_agg(jsonb_build_object(
        'independence_key', independence_key, 'base', contradiction_base,
        'reliability', reliability, 'recency_factor', recency_factor,
        'adjustment', adjustment) ORDER BY contribution_rank), '[]'::jsonb),
      'story_staleness_adjustment', 0, 'base_logit', ln(0.10 / 0.90),
      'total_adjustment', COALESCE(sum(adjustment), 0), 'normalization', 'pending-stage-5'
    ) AS details
  FROM contradiction_values
  HAVING count(*) > 0
), canonical_inputs AS (
  SELECT jsonb_build_object(
    'engine_version', 'probability-v1',
    'evaluated_at', requested_evaluated_at,
    'evidence', COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'raw_post_id', raw_post_id, 'posted_at', posted_at,
      'destination_club_name', destination_club_name,
      'independence_key', independence_key, 'reliability', reliability,
      'recency_factor', recency_factor, 'stage_signal', stage_signal,
      'claim_stance', claim_stance, 'wording_strength', wording_strength,
      'club_agreement_state', club_agreement_state,
      'personal_terms_state', personal_terms_state,
      'completion_claim', completion_claim
    ) ORDER BY independence_key, posted_at, raw_post_id, id)
      FILTER (WHERE active_rank = 1), '[]'::jsonb)
  )::text AS value
  FROM ranked
), reopen_final AS (
  SELECT reopen_output.*,
    reopen_output.details || jsonb_build_object(
      'raw_probability', probability, 'normalized_probability', probability) AS final_details,
    encode(sha256(convert_to(canonical_inputs.value, 'UTF8')), 'hex') AS fingerprint
  FROM reopen_output CROSS JOIN canonical_inputs
), contradiction_final AS (
  SELECT contradiction_output.*,
    contradiction_output.details || jsonb_build_object(
      'raw_probability', probability, 'normalized_probability', probability) AS final_details,
    encode(sha256(convert_to(canonical_inputs.value, 'UTF8')), 'hex') AS fingerprint
  FROM contradiction_output CROSS JOIN canonical_inputs
  WHERE NOT EXISTS (SELECT 1 FROM base)
    AND NOT EXISTS (SELECT 1 FROM official)
    AND NOT EXISTS (SELECT 1 FROM collapse)
)
SELECT base.raw_probability, base.normalized_probability, base.current_stage,
  base.explanation, base.input_fingerprint
FROM base WHERE NOT EXISTS (SELECT 1 FROM reopen_final)
UNION ALL
SELECT probability, probability, reopen_stage, final_details, fingerprint FROM reopen_final
UNION ALL
SELECT probability, probability, 'link', final_details, fingerprint FROM contradiction_final;
$$;

CREATE OR REPLACE FUNCTION settle_expired_probability_v1_cases(
  requested_mode text,
  requested_evaluated_at timestamptz,
  requested_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE eligible_case_ids bigint[]; selected_case_ids bigint[]; changed_sources bigint[];
  all_changed_sources bigint[] := '{}'::bigint[];
  batch_count integer; processed integer := 0; sources_locked boolean := false;
BEGIN
  IF requested_mode NOT IN ('shadow', 'active') THEN RETURN 0; END IF;
  IF requested_limit <= 0 THEN RETURN 0; END IF;

  SELECT array_agg(transfer_case.id ORDER BY transfer_case.id)
  INTO eligible_case_ids
  FROM transfer_cases transfer_case
  WHERE transfer_case.status IN ('open', 'collapsed')
    AND requested_evaluated_at >= probability_v1_window_expiry_at(
      transfer_case.transfer_window_key)
    AND EXISTS (SELECT 1 FROM source_claim_outcomes outcome
      WHERE outcome.transfer_case_id = transfer_case.id
        AND outcome.settlement_outcome IS NULL);

  IF eligible_case_ids IS NULL THEN RETURN 0; END IF;

  LOOP
    SELECT array_agg(claimed.id ORDER BY claimed.id)
    INTO selected_case_ids
    FROM (
      SELECT transfer_case.id
      FROM transfer_cases transfer_case
      WHERE transfer_case.id = ANY(eligible_case_ids)
        AND transfer_case.status IN ('open', 'collapsed')
        AND requested_evaluated_at >= probability_v1_window_expiry_at(
          transfer_case.transfer_window_key)
        AND EXISTS (SELECT 1 FROM source_claim_outcomes outcome
          WHERE outcome.transfer_case_id = transfer_case.id
            AND outcome.settlement_outcome IS NULL)
      ORDER BY transfer_case.id
      FOR UPDATE OF transfer_case SKIP LOCKED
      LIMIT LEAST(requested_limit, 100)
    ) claimed;

    batch_count := COALESCE(cardinality(selected_case_ids), 0);
    EXIT WHEN batch_count = 0;

    IF NOT sources_locked THEN
      PERFORM 1 FROM source_accounts source
      WHERE source.id IN (
        SELECT DISTINCT outcome.source_account_id
        FROM source_claim_outcomes outcome
        WHERE outcome.transfer_case_id = ANY(eligible_case_ids)
          AND outcome.settlement_outcome IS NULL
      )
      ORDER BY source.id FOR UPDATE;
      sources_locked := true;
    END IF;

    WITH changed AS (
      UPDATE source_claim_outcomes
      SET settlement_outcome = 'failure', settlement_basis = 'window_expiry',
          settled_at = requested_evaluated_at,
          authoritative_raw_post_id = NULL,
          authoritative_transfer_report_revision_id = NULL
      WHERE transfer_case_id = ANY(selected_case_ids) AND settlement_outcome IS NULL
      RETURNING source_account_id, transfer_case_id
    ), summarized AS (
      SELECT array_agg(DISTINCT source_account_id) AS source_ids,
        count(DISTINCT transfer_case_id)::integer AS case_count
      FROM changed
    )
    SELECT source_ids, case_count INTO changed_sources, batch_count FROM summarized;

    IF changed_sources IS NOT NULL THEN
      SELECT array_agg(DISTINCT source_account_id)
      INTO all_changed_sources
      FROM unnest(all_changed_sources || changed_sources) source_account_id;
      UPDATE transfer_cases SET status = 'closed' WHERE id = ANY(selected_case_ids);
      processed := processed + batch_count;
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
