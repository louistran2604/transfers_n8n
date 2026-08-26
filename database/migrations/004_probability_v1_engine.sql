CREATE FUNCTION probability_v1_reporter_posterior(
  seed_reliability numeric,
  success_weight numeric,
  failure_weight numeric
)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $$
  SELECT GREATEST(0.55, LEAST(0.95,
    (8 * seed_reliability + success_weight)
    / (8 + success_weight + failure_weight)
  ));
$$;

CREATE FUNCTION score_transfer_probability_v1(
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
WITH resolved AS (
  SELECT
    evidence.*,
    post.posted_at,
    post.source_account_id AS posting_account_id,
    COALESCE(evidence.resolved_independence_key, CASE
      WHEN originator.id IS NOT NULL THEN COALESCE(originator.publisher_group_key, 'source:' || originator.id)
      WHEN evidence.attribution_kind IN ('original', 'unknown') THEN COALESCE(posting.publisher_group_key, 'source:' || posting.id)
      ELSE 'unknown'
    END) AS independence_key,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,account_id}', '')::bigint,
      originator.id,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.id END,
      posting.id
    ) AS resolved_account_id,
    COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,source_kind}', originator.source_kind,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.source_kind END
    ) AS resolved_source_kind,
    COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,username}', originator.username,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.username END,
      posting.username
    ) AS source_username,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,seed_reliability}', '')::numeric,
      originator.seed_reliability,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.seed_reliability END
    ) AS resolved_seed_reliability,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,reliability_score}', '')::numeric,
      originator.reliability_score,
      CASE WHEN evidence.attribution_kind IN ('original', 'unknown') THEN posting.reliability_score END
    ) AS resolved_reliability_score
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
        resolved.resolved_seed_reliability,
        resolved.resolved_reliability_score,
        0.70
      )))
    )::numeric AS reliability,
    CASE resolved.wording_strength
      WHEN 'hedged' THEN 0.75 WHEN 'reported' THEN 0.90
      WHEN 'direct' THEN 1.00 WHEN 'definitive' THEN 1.10
    END::numeric AS wording_factor,
    CASE
      WHEN resolved.claim_stance = 'contradicts'
        OR resolved.club_agreement_state IN ('rejected', 'collapsed')
        OR resolved.personal_terms_state = 'rejected'
        OR resolved.stage_signal IN ('setback', 'collapsed') THEN 14
      WHEN resolved.stage_signal IN ('link', 'interest') THEN 7
      WHEN resolved.stage_signal IN ('agreed', 'done', 'official_wording')
        OR resolved.completion_claim <> 'none' THEN 30
      ELSE 14
    END::numeric AS half_life_days,
    GREATEST(0, EXTRACT(epoch FROM (requested_evaluated_at - resolved.posted_at)) / 86400)::numeric AS age_days
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
        CASE wording_strength WHEN 'definitive' THEN 4 WHEN 'direct' THEN 3 WHEN 'reported' THEN 2 ELSE 1 END DESC,
        raw_post_id DESC, id DESC
    ) AS active_rank
  FROM accepted
), active AS (
  SELECT * FROM ranked WHERE active_rank = 1
), terminal AS (
  SELECT ranked.*,
    CASE
      WHEN completion_claim = 'official_announcement'
        AND resolved_source_kind IN ('club_official', 'league_official') THEN 'official_confirmation'
      WHEN (stage_signal = 'collapsed' OR club_agreement_state = 'collapsed')
        AND resolved_source_kind IN ('club_official', 'league_official') THEN 'authoritative_collapse'
    END AS terminal_kind
  FROM ranked
  WHERE (completion_claim = 'official_announcement'
      AND resolved_source_kind IN ('club_official', 'league_official'))
    OR ((stage_signal = 'collapsed' OR club_agreement_state = 'collapsed')
      AND resolved_source_kind IN ('club_official', 'league_official'))
  ORDER BY CASE WHEN completion_claim = 'official_announcement' THEN 2 ELSE 1 END DESC,
    posted_at DESC,
    raw_post_id DESC, id DESC
  LIMIT 1
), support_pool AS (
  SELECT active.*,
    CASE
      WHEN completion_claim IN ('reporter_done', 'official_announcement')
        OR stage_signal IN ('done', 'official_wording') THEN 7
      WHEN stage_signal = 'agreed' THEN 6
      WHEN stage_signal = 'advanced' THEN 5
      WHEN stage_signal = 'talks' THEN 4
      WHEN stage_signal = 'interest' THEN 3
      WHEN stage_signal = 'link' THEN 2
    END AS support_rank
  FROM active
  WHERE claim_stance = 'supports'
    AND NOT EXISTS (SELECT 1 FROM terminal)
    AND (stage_signal IN ('link', 'interest', 'talks', 'advanced', 'agreed', 'done', 'official_wording')
      OR completion_claim <> 'none')
), support_scope AS (
  SELECT support_pool.*
  FROM support_pool
  WHERE independence_key <> 'unknown'
    OR NOT EXISTS (SELECT 1 FROM support_pool WHERE independence_key <> 'unknown')
), gates AS (
  SELECT
    COALESCE(bool_or(personal_terms_state = 'agreed'), false) AS personal_satisfied,
    COALESCE(bool_or(club_agreement_state IN ('agreed', 'not_applicable')), false) AS club_satisfied
  FROM support_scope
), stage AS (
  SELECT
    CASE
      WHEN EXISTS (SELECT 1 FROM terminal WHERE terminal_kind = 'official_confirmation') THEN 'done'
      WHEN EXISTS (SELECT 1 FROM terminal WHERE terminal_kind = 'authoritative_collapse') THEN 'collapsed'
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 7) THEN 'done'
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 6)
        AND gates.personal_satisfied AND gates.club_satisfied THEN 'agreed'
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 6)
        AND (gates.personal_satisfied OR gates.club_satisfied) THEN 'agreed'
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 5) THEN 'advanced'
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 4) THEN 'talks'
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 3) THEN 'interest'
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 2) THEN 'link'
    END AS name,
    CASE
      WHEN EXISTS (SELECT 1 FROM terminal WHERE terminal_kind = 'official_confirmation') THEN 1.00
      WHEN EXISTS (SELECT 1 FROM terminal WHERE terminal_kind = 'authoritative_collapse') THEN 0.02
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 7) THEN 0.97
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 6)
        AND gates.personal_satisfied AND gates.club_satisfied THEN 0.90
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 6)
        AND (gates.personal_satisfied OR gates.club_satisfied) THEN 0.72
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 5) THEN 0.55
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 4) THEN 0.35
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 3) THEN 0.18
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 2) THEN 0.10
    END::numeric AS base,
    CASE
      WHEN EXISTS (SELECT 1 FROM terminal WHERE terminal_kind = 'official_confirmation') THEN 1.00
      WHEN EXISTS (SELECT 1 FROM terminal WHERE terminal_kind = 'authoritative_collapse') THEN 0.05
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 7) THEN 0.98
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 6)
        AND gates.personal_satisfied AND gates.club_satisfied THEN 0.97
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank = 6)
        AND (gates.personal_satisfied OR gates.club_satisfied) THEN 0.90
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 5) THEN 0.82
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 4) THEN 0.65
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 3) THEN 0.45
      WHEN EXISTS (SELECT 1 FROM support_scope WHERE support_rank >= 2) THEN 0.25
    END::numeric AS ceiling,
    (SELECT terminal_kind FROM terminal) AS terminal_kind
  FROM gates
), primary_source AS (
  SELECT support_scope.*,
    GREATEST(-0.50, LEAST(0.50, 2 * (reliability - 0.75)))
      * wording_factor * recency_factor AS adjustment
  FROM support_scope
  ORDER BY support_rank DESC,
    abs(GREATEST(-0.50, LEAST(0.50, 2 * (reliability - 0.75))) * wording_factor * recency_factor) DESC,
    independence_key, raw_post_id DESC, id DESC
  LIMIT 1
), corroborator_candidates AS (
  SELECT support_scope.*,
    0.65 * GREATEST(0.25, LEAST(1.00, (reliability - 0.50) / 0.45))
      * wording_factor * recency_factor AS undiminished
  FROM support_scope
  WHERE independence_key <> 'unknown'
    AND id <> COALESCE((SELECT id FROM primary_source), -1)
), corroborators AS (
  SELECT corroborator_candidates.*,
    row_number() OVER (ORDER BY abs(undiminished) DESC, independence_key) AS contribution_rank
  FROM corroborator_candidates
), corroboration AS (
  SELECT *, undiminished * CASE contribution_rank
    WHEN 1 THEN 1.00 WHEN 2 THEN 0.70 WHEN 3 THEN 0.50 ELSE 0.25
  END AS adjustment
  FROM corroborators
), contradiction_candidates AS (
  SELECT active.*,
    CASE
      WHEN club_agreement_state = 'rejected' OR personal_terms_state = 'rejected' THEN -0.80
      WHEN stage_signal = 'setback' THEN -0.60
      WHEN claim_stance = 'contradicts' OR stage_signal = 'collapsed' OR club_agreement_state = 'collapsed' THEN -1.60
    END::numeric AS contradiction_base
  FROM active
  WHERE club_agreement_state = 'rejected' OR personal_terms_state = 'rejected'
    OR stage_signal = 'setback' OR claim_stance = 'contradicts'
    OR stage_signal = 'collapsed' OR club_agreement_state = 'collapsed'
), contradiction_order AS (
  SELECT contradiction_candidates.*,
    contradiction_base * GREATEST(0.25, LEAST(1.00, (reliability - 0.50) / 0.45))
      * wording_factor * recency_factor AS undiminished,
    row_number() OVER (ORDER BY
      abs(contradiction_base * GREATEST(0.25, LEAST(1.00, (reliability - 0.50) / 0.45)) * wording_factor * recency_factor) DESC,
      independence_key
    ) AS contribution_rank
  FROM contradiction_candidates
  WHERE NOT EXISTS (SELECT 1 FROM terminal)
), contradictions AS (
  SELECT *, undiminished * CASE contribution_rank
    WHEN 1 THEN 1.00 WHEN 2 THEN 0.70 WHEN 3 THEN 0.50 ELSE 0.25
  END AS adjustment
  FROM contradiction_order
), newest_support AS (
  SELECT * FROM support_scope ORDER BY posted_at DESC, raw_post_id DESC, id DESC LIMIT 1
), adjustments AS (
  SELECT
    COALESCE((SELECT adjustment FROM primary_source), 0)::numeric AS primary_adjustment,
    COALESCE((SELECT sum(adjustment) FROM corroboration), 0)::numeric AS corroboration_adjustment,
    COALESCE((SELECT sum(adjustment) FROM contradictions), 0)::numeric AS contradiction_adjustment,
    COALESCE((SELECT GREATEST(-1.40, -0.35 * (age_days / half_life_days - 1))
      FROM newest_support WHERE age_days > half_life_days), 0)::numeric AS staleness_adjustment
), numeric_result AS (
  SELECT stage.*,
    CASE WHEN stage.base IN (0, 1) THEN NULL ELSE ln(stage.base / (1 - stage.base)) END AS base_logit,
    adjustments.*,
    adjustments.primary_adjustment + adjustments.corroboration_adjustment
      + adjustments.contradiction_adjustment + adjustments.staleness_adjustment AS total_adjustment
  FROM stage CROSS JOIN adjustments
), result AS (
  SELECT numeric_result.*,
    CASE
      WHEN terminal_kind = 'official_confirmation' THEN 1::numeric
      WHEN terminal_kind = 'authoritative_collapse' THEN 0.02::numeric
      ELSE 1 / (1 + exp(-(base_logit + total_adjustment)))
    END AS unclamped_probability
  FROM numeric_result
), canonical_inputs AS (
  SELECT jsonb_build_object(
    'engine_version', 'probability-v1',
    'evaluated_at', requested_evaluated_at,
    'evidence', COALESCE(jsonb_agg(jsonb_build_object(
      'id', id, 'raw_post_id', raw_post_id, 'posted_at', posted_at,
      'destination_club_name', destination_club_name,
      'source_account_id', resolved_account_id,
      'source_username', source_username,
      'source_kind', resolved_source_kind,
      'independence_key', independence_key, 'reliability', reliability,
      'recency_factor', recency_factor,
      'stage_signal', stage_signal, 'claim_stance', claim_stance,
      'wording_strength', wording_strength, 'club_agreement_state', club_agreement_state,
      'personal_terms_state', personal_terms_state, 'completion_claim', completion_claim
    ) ORDER BY independence_key, posted_at, raw_post_id, id), '[]'::jsonb)
  )::text AS value
  FROM ranked
), breakdown AS (
  SELECT result.*,
    LEAST(result.ceiling, result.unclamped_probability)::numeric AS final_probability,
    jsonb_build_object(
      'engine_version', 'probability-v1',
      'evaluated_at', requested_evaluated_at,
      'stage', jsonb_build_object('name', result.name, 'base', result.base, 'ceiling', result.ceiling, 'terminal_kind', result.terminal_kind),
      'terminal_kind', result.terminal_kind,
      'primary', COALESCE((SELECT jsonb_build_object(
        'source_account', source_username, 'independence_key', independence_key,
        'reliability', reliability, 'wording_factor', wording_factor,
        'recency_factor', recency_factor, 'adjustment', adjustment
      ) FROM primary_source), (SELECT jsonb_build_object(
        'source_account', source_username, 'independence_key', independence_key,
        'reliability', reliability, 'wording_factor', wording_factor,
        'recency_factor', 1, 'adjustment', 0
      ) FROM terminal), '{}'::jsonb),
      'corroboration', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'independence_key', independence_key, 'reliability', reliability,
        'wording_factor', wording_factor, 'recency_factor', recency_factor,
        'diminishing_factor', adjustment / NULLIF(undiminished, 0), 'adjustment', adjustment
      ) ORDER BY contribution_rank) FROM corroboration), '[]'::jsonb),
      'contradictions', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'independence_key', independence_key, 'base', contradiction_base,
        'reliability', reliability, 'wording_factor', wording_factor,
        'recency_factor', recency_factor,
        'diminishing_factor', adjustment / NULLIF(undiminished, 0), 'adjustment', adjustment
      ) ORDER BY contribution_rank) FROM contradictions), '[]'::jsonb),
      'story_staleness_adjustment', result.staleness_adjustment,
      'base_logit', result.base_logit,
      'total_adjustment', result.total_adjustment,
      'unclamped_logit', result.base_logit + result.total_adjustment,
      'unclamped_probability', result.unclamped_probability,
      'raw_probability', round(LEAST(result.ceiling, result.unclamped_probability), 5),
      'normalized_probability', round(LEAST(result.ceiling, result.unclamped_probability), 5),
      'normalization', 'pending-stage-5'
    ) AS details
  FROM result
)
SELECT
  round(breakdown.final_probability, 5),
  round(breakdown.final_probability, 5),
  breakdown.name,
  breakdown.details,
  encode(sha256(convert_to(canonical_inputs.value, 'UTF8')), 'hex')
FROM breakdown CROSS JOIN canonical_inputs
WHERE breakdown.name IS NOT NULL;
$$;

CREATE FUNCTION apply_probability_v1_shadow(
  requested_transfer_report_id bigint,
  payload jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  evaluated_at timestamptz;
  evidence_posted_at timestamptz;
  v_transfer_case_id bigint;
  existing_transfer_case_id bigint;
  player_identity_key text;
  normalized_current_club text;
  window_key text;
  stable_case_key text;
  prior_probability numeric;
  scored record;
  probability_revision_id bigint;
BEGIN
  IF payload->>'probability_mode' IS DISTINCT FROM 'shadow' THEN
    RETURN NULL;
  END IF;
  evaluated_at := (payload->>'evaluated_at')::timestamptz;

  SELECT player.identity_key,
    COALESCE(NULLIF(payload #>> '{normalized_data,current_club_key}', ''), 'unknown'),
    report.raw_probability, report.transfer_case_id
  INTO player_identity_key, normalized_current_club, prior_probability, existing_transfer_case_id
  FROM transfer_reports report
  JOIN players player ON player.id = report.player_id
  WHERE report.id = requested_transfer_report_id
  FOR UPDATE OF report;

  SELECT (source->>'posted_at')::timestamptz
  INTO evidence_posted_at
  FROM jsonb_array_elements(payload->'sources') source
  ORDER BY (source->>'posted_at')::timestamptz, (source->>'raw_post_id')::bigint
  LIMIT 1;
  window_key := to_char(evidence_posted_at AT TIME ZONE 'UTC', 'YYYY') ||
    CASE WHEN EXTRACT(month FROM evidence_posted_at AT TIME ZONE 'UTC') <= 6 THEN '-H1' ELSE '-H2' END;
  stable_case_key := player_identity_key || '|' || normalized_current_club || '|' || window_key;

  IF existing_transfer_case_id IS NULL THEN
    INSERT INTO transfer_cases (
      case_key, player_id, normalized_current_club, transfer_window_key
    )
    SELECT stable_case_key, report.player_id,
      NULLIF(normalized_current_club, 'unknown'), window_key
    FROM transfer_reports report
    WHERE report.id = requested_transfer_report_id
    ON CONFLICT (case_key) DO NOTHING
    RETURNING id INTO v_transfer_case_id;
    IF v_transfer_case_id IS NULL THEN
      SELECT id INTO v_transfer_case_id
      FROM transfer_cases
      WHERE case_key = stable_case_key
      FOR UPDATE;
    END IF;
    UPDATE transfer_reports
    SET transfer_case_id = v_transfer_case_id
    WHERE id = requested_transfer_report_id;
  ELSE
    SELECT id INTO v_transfer_case_id
    FROM transfer_cases
    WHERE id = existing_transfer_case_id
    FOR UPDATE;
  END IF;

  INSERT INTO transfer_evidence (
    transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
    report_ordinal, destination_club_name, stage_signal, claim_stance,
    wording_strength, club_agreement_state, personal_terms_state, completion_claim,
    attribution_kind, named_originator, resolved_independence_key,
    extraction_confidence, raw_normalized_extraction
  )
  SELECT
    requested_transfer_report_id, v_transfer_case_id, (source->>'raw_post_id')::bigint,
    source->>'extraction_schema_version', (source->>'report_ordinal')::integer,
    NULLIF(payload->>'destination_club_name', ''),
    source #>> '{normalized_evidence,stage_signal}',
    source #>> '{normalized_evidence,claim_stance}',
    source #>> '{normalized_evidence,wording_strength}',
    source #>> '{normalized_evidence,club_agreement_state}',
    source #>> '{normalized_evidence,personal_terms_state}',
    source #>> '{normalized_evidence,completion_claim}',
    source #>> '{normalized_evidence,attribution_kind}',
    NULLIF(source #>> '{normalized_evidence,named_originator}', ''),
    CASE
      WHEN resolved_source.id IS NOT NULL
        THEN COALESCE(resolved_source.publisher_group_key, 'source:' || resolved_source.id)
      ELSE 'unknown'
    END,
    (source #>> '{normalized_evidence,extraction_confidence}')::numeric,
    source->'normalized_evidence' || jsonb_build_object(
      '_resolved_source', jsonb_strip_nulls(jsonb_build_object(
        'account_id', COALESCE(resolved_source.id, posting.id),
        'username', COALESCE(resolved_source.username, posting.username),
        'source_kind', resolved_source.source_kind,
        'seed_reliability', resolved_source.seed_reliability,
        'reliability_score', resolved_source.reliability_score
      ))
    )
  FROM jsonb_array_elements(payload->'sources') source
  JOIN raw_posts post ON post.id = (source->>'raw_post_id')::bigint
  JOIN source_accounts posting ON posting.id = post.source_account_id
  LEFT JOIN LATERAL (
    SELECT account.*
    FROM source_accounts account
    WHERE NULLIF(source #>> '{normalized_evidence,named_originator}', '') IS NOT NULL
      AND lower(account.username) = lower(regexp_replace(source #>> '{normalized_evidence,named_originator}', '^@', ''))
      AND account.is_active
    ORDER BY account.id
    LIMIT 1
  ) originator ON true
  LEFT JOIN LATERAL (
    SELECT account.*
    FROM source_accounts account
    WHERE account.id = COALESCE(
      originator.id,
      CASE WHEN source #>> '{normalized_evidence,attribution_kind}' IN ('original', 'unknown')
        THEN posting.id END
    )
  ) resolved_source ON true
  ON CONFLICT (raw_post_id, report_ordinal, extraction_schema_version) DO NOTHING;

  SELECT * INTO scored
  FROM score_transfer_probability_v1(requested_transfer_report_id, evaluated_at);
  IF NOT FOUND THEN
    RETURN NULL;
  END IF;

  INSERT INTO transfer_probability_revisions (
    transfer_report_id, transfer_case_id, revision_number, engine_version,
    evaluated_at, raw_probability, normalized_probability, previous_probability,
    probability_delta, current_stage, explanation, input_fingerprint
  ) VALUES (
    requested_transfer_report_id, v_transfer_case_id,
    COALESCE((SELECT max(revision_number) + 1 FROM transfer_probability_revisions
      WHERE transfer_report_id = requested_transfer_report_id), 1),
    'probability-v1', evaluated_at, scored.raw_probability, scored.normalized_probability,
    prior_probability, CASE WHEN prior_probability IS NULL THEN NULL ELSE scored.raw_probability - prior_probability END,
    scored.current_stage, scored.explanation, scored.input_fingerprint
  )
  ON CONFLICT (transfer_report_id, input_fingerprint, engine_version) DO NOTHING
  RETURNING id INTO probability_revision_id;

  IF probability_revision_id IS NULL THEN
    SELECT id INTO probability_revision_id
    FROM transfer_probability_revisions
    WHERE transfer_report_id = requested_transfer_report_id
      AND input_fingerprint = scored.input_fingerprint
      AND engine_version = 'probability-v1';
  ELSE
    UPDATE transfer_cases
    SET version_counter = version_counter + 1,
        probability_engine_version = 'probability-v1'
    WHERE id = v_transfer_case_id;
  END IF;

  UPDATE transfer_reports
  SET transfer_stage = scored.current_stage,
      raw_probability = scored.raw_probability,
      normalized_probability = scored.normalized_probability,
      probability_engine_version = 'probability-v1',
      probability_explanation = scored.explanation,
      probability_updated_at = evaluated_at
  WHERE id = requested_transfer_report_id;

  RETURN probability_revision_id;
END;
$$;
