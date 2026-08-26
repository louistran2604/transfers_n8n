CREATE FUNCTION probability_v1_validate_official_outcomes(
  requested_transfer_case_id bigint,
  outcome_count bigint
)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF outcome_count > 1 THEN
    RAISE EXCEPTION USING
      ERRCODE = '23514',
      MESSAGE = format('transfer case %s has conflicting official destinations', requested_transfer_case_id);
  END IF;
  RETURN true;
END;
$$;

CREATE FUNCTION probability_v1_case_scores(
  requested_transfer_case_id bigint,
  requested_evaluated_at timestamptz
)
RETURNS TABLE (
  transfer_report_id bigint,
  raw_probability numeric,
  normalized_probability numeric,
  current_stage text,
  raw_explanation jsonb,
  raw_input_fingerprint text,
  stay_probability numeric,
  normalization_inputs jsonb,
  input_fingerprint text
)
LANGUAGE sql
STABLE
AS $$
WITH raw_scores AS (
  SELECT report.id AS report_id, report.destination_club_name,
    scored.raw_probability, scored.current_stage,
    scored.explanation, scored.input_fingerprint
  FROM transfer_reports report
  CROSS JOIN LATERAL score_transfer_probability_v1(report.id, requested_evaluated_at) scored
  WHERE report.transfer_case_id = requested_transfer_case_id
), official_outcomes AS (
  SELECT min(report_id) AS report_id, count(*) AS outcome_count
  FROM raw_scores
  WHERE raw_probability = 1.00000
), validated_official_outcomes AS MATERIALIZED (
  SELECT report_id, outcome_count
  FROM official_outcomes
  WHERE probability_v1_validate_official_outcomes(
    requested_transfer_case_id, outcome_count
  )
), destination_odds AS (
  SELECT raw_scores.*,
    CASE WHEN raw_probability = 1 THEN NULL
      ELSE raw_probability / (1 - raw_probability) END AS odds
  FROM raw_scores
), denominator AS (
  SELECT 1 + COALESCE(sum(odds), 0) AS value
  FROM destination_odds
  WHERE NOT EXISTS (SELECT 1 FROM validated_official_outcomes WHERE report_id IS NOT NULL)
), ideal_items AS (
  SELECT 'destination'::text AS kind, destination_odds.report_id,
    CASE
      WHEN validated_official_outcomes.report_id IS NOT NULL
        THEN (destination_odds.report_id = validated_official_outcomes.report_id)::integer::numeric
      ELSE destination_odds.odds / denominator.value
    END AS ideal_share
  FROM destination_odds CROSS JOIN validated_official_outcomes CROSS JOIN denominator
  UNION ALL
  SELECT 'stay', NULL::bigint,
    CASE WHEN validated_official_outcomes.report_id IS NOT NULL THEN 0::numeric
      ELSE 1 / denominator.value END
  FROM validated_official_outcomes CROSS JOIN denominator
), item_units AS (
  SELECT ideal_items.*,
    floor(ideal_share * 100000)::integer AS base_units,
    ideal_share * 100000 - floor(ideal_share * 100000) AS fractional_units
  FROM ideal_items
), ranked_items AS (
  SELECT item_units.*,
    (100000 - sum(base_units) OVER ())::integer AS remaining_units,
    row_number() OVER (
      ORDER BY fractional_units DESC, kind, report_id NULLS LAST
    ) AS remainder_rank
  FROM item_units
), final_items AS (
  SELECT kind, report_id,
    (base_units + CASE WHEN remainder_rank <= remaining_units THEN 1 ELSE 0 END)::numeric
      / 100000 AS final_share
  FROM ranked_items
), destination_scores AS (
  SELECT destination_odds.*,
    final_items.final_share AS normalized_probability
  FROM destination_odds
  JOIN final_items ON final_items.kind = 'destination'
    AND final_items.report_id = destination_odds.report_id
), normalization AS (
  SELECT
    (SELECT final_share FROM final_items WHERE kind = 'stay') AS stay_probability,
    jsonb_agg(jsonb_build_object(
      'report_id', report_id,
      'destination_club_name', destination_club_name,
      'raw_probability', raw_probability,
      'odds', odds,
      'normalized_probability', normalized_probability,
      'raw_input_fingerprint', input_fingerprint
    ) ORDER BY report_id) AS inputs
  FROM destination_scores
)
SELECT destination_scores.report_id,
  destination_scores.raw_probability,
  destination_scores.normalized_probability,
  destination_scores.current_stage,
  destination_scores.explanation,
  destination_scores.input_fingerprint,
  normalization.stay_probability,
  normalization.inputs,
  encode(sha256(convert_to(jsonb_build_object(
    'raw_input_fingerprint', destination_scores.input_fingerprint,
    'normalization_inputs', normalization.inputs,
    'stay_probability', normalization.stay_probability
  )::text, 'UTF8')), 'hex')
FROM destination_scores CROSS JOIN normalization
ORDER BY destination_scores.report_id;
$$;

CREATE OR REPLACE FUNCTION apply_probability_v1_shadow(
  requested_transfer_report_id bigint,
  payload jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_evaluated_at timestamptz;
  evidence_posted_at timestamptz;
  v_transfer_case_id bigint;
  existing_transfer_case_id bigint;
  player_identity_key text;
  normalized_current_club text;
  window_key text;
  stable_case_key text;
  inserted_revision_count integer;
  locked_report_count integer;
  probability_revision_id bigint;
BEGIN
  IF payload->>'probability_mode' IS DISTINCT FROM 'shadow' THEN
    RETURN NULL;
  END IF;
  v_evaluated_at := (payload->>'evaluated_at')::timestamptz;

  SELECT player.identity_key,
    COALESCE(NULLIF(payload #>> '{normalized_data,current_club_key}', ''), 'unknown'),
    report.transfer_case_id
  INTO player_identity_key, normalized_current_club, existing_transfer_case_id
  FROM transfer_reports report
  JOIN players player ON player.id = report.player_id
  WHERE report.id = requested_transfer_report_id;

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
      WHERE case_key = stable_case_key;
    END IF;
  ELSE
    v_transfer_case_id := existing_transfer_case_id;
  END IF;

  PERFORM 1
  FROM transfer_cases
  WHERE id = v_transfer_case_id
  FOR UPDATE;

  PERFORM 1
  FROM transfer_reports report
  WHERE report.transfer_case_id = v_transfer_case_id
  ORDER BY report.id
  FOR UPDATE;

  IF existing_transfer_case_id IS NULL THEN
    UPDATE transfer_reports
    SET transfer_case_id = v_transfer_case_id
    WHERE id = requested_transfer_report_id
      AND (transfer_case_id IS NULL OR transfer_case_id = v_transfer_case_id);
    GET DIAGNOSTICS locked_report_count = ROW_COUNT;
    IF locked_report_count <> 1 THEN
      RAISE EXCEPTION 'transfer report % was assigned to a different case', requested_transfer_report_id;
    END IF;
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

  IF NOT EXISTS (
    SELECT 1 FROM probability_v1_case_scores(v_transfer_case_id, v_evaluated_at)
  ) THEN
    RETURN NULL;
  END IF;

  INSERT INTO transfer_probability_revisions (
    transfer_report_id, transfer_case_id, revision_number, engine_version,
    evaluated_at, raw_probability, normalized_probability, previous_probability,
    probability_delta, current_stage, explanation, input_fingerprint
  )
  SELECT score.transfer_report_id, v_transfer_case_id,
    COALESCE(previous.revision_number + 1, 1), 'probability-v1', v_evaluated_at,
    score.raw_probability, score.normalized_probability, previous.normalized_probability,
    CASE WHEN previous.id IS NULL THEN NULL
      ELSE score.normalized_probability - previous.normalized_probability END,
    score.current_stage,
    score.raw_explanation || jsonb_build_object(
      'raw_probability', score.raw_probability,
      'normalized_probability', score.normalized_probability,
      'competition_adjustment', score.normalized_probability - score.raw_probability,
      'previous_probability', previous.normalized_probability,
      'delta', CASE WHEN previous.id IS NULL THEN NULL
        ELSE score.normalized_probability - previous.normalized_probability END,
      'stay_probability', score.stay_probability,
      'normalization_inputs', score.normalization_inputs,
      'normalization', 'case-level-destination-stay',
      'raw_input_fingerprint', score.raw_input_fingerprint,
      'change_classification', CASE
        WHEN previous.id IS NULL THEN 'initial'
        WHEN previous.explanation->>'raw_input_fingerprint' = score.raw_input_fingerprint
          AND previous.normalized_probability <> score.normalized_probability THEN 'competition_only'
        WHEN previous.explanation->>'raw_input_fingerprint' = score.raw_input_fingerprint
          THEN 'competition_inputs_changed'
        ELSE 'raw_score_change'
      END
    ),
    score.input_fingerprint
  FROM probability_v1_case_scores(v_transfer_case_id, v_evaluated_at) score
  LEFT JOIN LATERAL (
    SELECT revision.*
    FROM transfer_probability_revisions revision
    WHERE revision.transfer_report_id = score.transfer_report_id
      AND revision.engine_version = 'probability-v1'
    ORDER BY revision.revision_number DESC
    LIMIT 1
  ) previous ON true
  ON CONFLICT (transfer_report_id, input_fingerprint, engine_version) DO NOTHING;
  GET DIAGNOSTICS inserted_revision_count = ROW_COUNT;

  UPDATE transfer_reports report
  SET transfer_stage = score.current_stage,
      raw_probability = score.raw_probability,
      normalized_probability = score.normalized_probability,
      probability_engine_version = 'probability-v1',
      probability_explanation = revision.explanation,
      probability_updated_at = v_evaluated_at
  FROM probability_v1_case_scores(v_transfer_case_id, v_evaluated_at) score
  JOIN transfer_probability_revisions revision
    ON revision.transfer_report_id = score.transfer_report_id
    AND revision.input_fingerprint = score.input_fingerprint
    AND revision.engine_version = 'probability-v1'
  WHERE report.id = score.transfer_report_id;

  UPDATE transfer_cases
  SET stay_probability = score.stay_probability,
      probability_engine_version = 'probability-v1',
      version_counter = version_counter + CASE WHEN inserted_revision_count > 0 THEN 1 ELSE 0 END
  FROM (
    SELECT stay_probability
    FROM probability_v1_case_scores(v_transfer_case_id, v_evaluated_at)
    LIMIT 1
  ) score
  WHERE id = v_transfer_case_id;

  SELECT revision.id INTO probability_revision_id
  FROM probability_v1_case_scores(v_transfer_case_id, v_evaluated_at) score
  JOIN transfer_probability_revisions revision
    ON revision.transfer_report_id = score.transfer_report_id
    AND revision.input_fingerprint = score.input_fingerprint
    AND revision.engine_version = 'probability-v1'
  WHERE score.transfer_report_id = requested_transfer_report_id;

  RETURN probability_revision_id;
END;
$$;
