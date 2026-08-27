-- Keep the previously deployed scorer available for unchanged inputs while
-- repairing the two state transitions that it could not represent.
ALTER FUNCTION score_transfer_probability_v1(bigint, timestamptz)
  RENAME TO score_transfer_probability_v1_pre_final_review;

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
), evidence_rows AS (
  SELECT evidence.id, evidence.raw_post_id, evidence.destination_club_name,
    evidence.stage_signal, evidence.claim_stance, evidence.wording_strength,
    evidence.club_agreement_state, evidence.personal_terms_state,
    evidence.completion_claim, evidence.extraction_confidence,
    evidence.resolved_independence_key, evidence.raw_normalized_extraction,
    post.posted_at, posting.id AS posting_account_id,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,account_id}', '')::bigint,
      posting.id) AS resolved_account_id,
    COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,source_kind}', posting.source_kind)
      AS source_kind,
    COALESCE(evidence.raw_normalized_extraction #>> '{_resolved_source,username}', posting.username)
      AS source_username,
    COALESCE(NULLIF(evidence.raw_normalized_extraction #>> '{_resolved_source,seed_reliability}', '')::numeric,
      posting.seed_reliability, posting.reliability_score, 0.70)::numeric AS reliability,
    COALESCE(evidence.resolved_independence_key,
      posting.publisher_group_key, 'source:' || posting.id) AS independence_key,
    GREATEST(0, EXTRACT(epoch FROM (requested_evaluated_at - post.posted_at)) / 86400)::numeric AS age_days
  FROM transfer_evidence evidence
  JOIN raw_posts post ON post.id = evidence.raw_post_id
  JOIN source_accounts posting ON posting.id = post.source_account_id
  WHERE evidence.transfer_report_id = requested_transfer_report_id
    AND evidence.extraction_confidence >= 0.50
    AND post.posted_at <= requested_evaluated_at
), ranked AS (
  SELECT evidence_rows.*,
    CASE
      WHEN source_kind IN ('club_official', 'league_official')
        AND (completion_claim = 'official_announcement'
          OR stage_signal = 'collapsed' OR club_agreement_state = 'collapsed') THEN 1::numeric
      ELSE power(2::numeric, -age_days / 14)
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
  FROM evidence_rows
), official AS (
  SELECT 1 AS present
  FROM ranked
  WHERE source_kind IN ('club_official', 'league_official')
    AND completion_claim = 'official_announcement'
  LIMIT 1
), collapse AS (
  SELECT ranked.*
  FROM ranked
  WHERE source_kind IN ('club_official', 'league_official')
    AND (stage_signal = 'collapsed' OR club_agreement_state = 'collapsed')
  ORDER BY posted_at DESC, raw_post_id DESC, id DESC
  LIMIT 1
), later_advanced AS (
  SELECT ranked.*
  FROM ranked
  CROSS JOIN collapse
  WHERE NOT EXISTS (SELECT 1 FROM official)
    AND ranked.claim_stance = 'supports'
    AND ranked.posted_at > collapse.posted_at
    AND (
      ranked.stage_signal IN ('advanced', 'agreed', 'done', 'official_wording')
      OR ranked.completion_claim = 'reporter_done'
    )
  ORDER BY ranked.posted_at DESC,
    CASE ranked.stage_signal
      WHEN 'official_wording' THEN 5 WHEN 'done' THEN 4 WHEN 'agreed' THEN 3
      WHEN 'advanced' THEN 2 ELSE 1 END DESC,
    ranked.raw_post_id DESC, ranked.id DESC
  LIMIT 1
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
    END AS reopen_ceiling,
    CASE wording_strength
      WHEN 'hedged' THEN 0.75 WHEN 'reported' THEN 0.90
      WHEN 'direct' THEN 1.00 WHEN 'definitive' THEN 1.10
    END::numeric AS reopen_wording_factor,
    power(2::numeric, -age_days / CASE
      WHEN completion_claim = 'reporter_done' OR stage_signal IN ('done', 'official_wording') THEN 30
      ELSE 14 END)::numeric AS reopen_recency_factor
  FROM later_advanced
), reopen_scored AS (
  SELECT reopen_values.*,
    GREATEST(-0.50, LEAST(0.50, 2 * (reliability - 0.75)))
      * reopen_wording_factor * reopen_recency_factor AS primary_adjustment
  FROM reopen_values
), reopen_result AS (
  SELECT reopen_scored.*,
    LEAST(reopen_ceiling,
      1 / (1 + exp(-(
        ln(reopen_base / (1 - reopen_base)) + primary_adjustment
      ))))::numeric AS final_probability
  FROM reopen_scored
), contradiction_candidates AS (
  SELECT ranked.*,
    CASE
      WHEN club_agreement_state = 'rejected' OR personal_terms_state = 'rejected' THEN -0.80::numeric
      WHEN stage_signal = 'setback' THEN -0.60::numeric
      ELSE -1.60::numeric
    END AS contradiction_base,
    row_number() OVER (
      ORDER BY abs(CASE
        WHEN club_agreement_state = 'rejected' OR personal_terms_state = 'rejected' THEN -0.80::numeric
        WHEN stage_signal = 'setback' THEN -0.60::numeric
        ELSE -1.60::numeric END)
        * GREATEST(0.25, LEAST(1.00, (reliability - 0.50) / 0.45))
        * CASE wording_strength
            WHEN 'hedged' THEN 0.75 WHEN 'reported' THEN 0.90
            WHEN 'direct' THEN 1.00 WHEN 'definitive' THEN 1.10 END
        * recency_factor DESC,
      independence_key, raw_post_id DESC, id DESC
    ) AS contribution_rank
  FROM ranked
  WHERE active_rank = 1
    AND (club_agreement_state = 'rejected' OR personal_terms_state = 'rejected'
      OR stage_signal = 'setback' OR claim_stance = 'contradicts'
      OR stage_signal = 'collapsed' OR club_agreement_state = 'collapsed')
), contradiction_values AS (
  SELECT contradiction_candidates.*,
    contradiction_base
      * GREATEST(0.25, LEAST(1.00, (reliability - 0.50) / 0.45))
      * CASE wording_strength
          WHEN 'hedged' THEN 0.75 WHEN 'reported' THEN 0.90
          WHEN 'direct' THEN 1.00 WHEN 'definitive' THEN 1.10 END
      * recency_factor
      * CASE contribution_rank WHEN 1 THEN 1.00 WHEN 2 THEN 0.70
        WHEN 3 THEN 0.50 ELSE 0.25 END AS adjustment
  FROM contradiction_candidates
), contradiction_result AS (
  SELECT
    LEAST(0.25::numeric, 1 / (1 + exp(-(
      ln(0.10 / 0.90) + COALESCE(sum(adjustment), 0)
    )))::numeric) AS final_probability,
    COALESCE(jsonb_agg(jsonb_build_object(
      'independence_key', independence_key, 'base', contradiction_base,
      'reliability', reliability, 'recency_factor', recency_factor,
      'adjustment', adjustment
    ) ORDER BY contribution_rank), '[]'::jsonb) AS contradictions
  FROM contradiction_values
), canonical_inputs AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id, 'raw_post_id', raw_post_id, 'posted_at', posted_at,
    'destination_club_name', destination_club_name,
    'independence_key', independence_key, 'reliability', reliability,
    'stage_signal', stage_signal, 'claim_stance', claim_stance,
    'wording_strength', wording_strength,
    'club_agreement_state', club_agreement_state,
    'personal_terms_state', personal_terms_state,
    'completion_claim', completion_claim
  ) ORDER BY independence_key, posted_at, raw_post_id, id), '[]'::jsonb) AS value
  FROM ranked
), contradiction_output AS (
  SELECT contradiction_result.final_probability,
    encode(sha256(convert_to(canonical_inputs.value::text, 'UTF8')), 'hex') AS fingerprint,
    jsonb_build_object(
      'engine_version', 'probability-v1',
      'evaluated_at', requested_evaluated_at,
      'stage', jsonb_build_object('name', 'link', 'base', 0.10, 'ceiling', 0.25),
      'terminal_kind', NULL,
      'primary', '{}',
      'corroboration', '[]'::jsonb,
      'contradictions', contradiction_result.contradictions,
      'story_staleness_adjustment', 0,
      'base_logit', ln(0.10 / 0.90),
      'total_adjustment', COALESCE((SELECT sum(adjustment) FROM contradiction_values), 0),
      'raw_probability', round(contradiction_result.final_probability, 5),
      'normalized_probability', round(contradiction_result.final_probability, 5),
      'normalization', 'pending-stage-5'
    ) AS details
  FROM contradiction_result CROSS JOIN canonical_inputs
  WHERE NOT EXISTS (SELECT 1 FROM base)
    AND NOT EXISTS (SELECT 1 FROM official)
    AND NOT EXISTS (SELECT 1 FROM collapse)
    AND EXISTS (SELECT 1 FROM contradiction_values)
), reopen_output AS (
  SELECT round(final_probability, 5) AS final_probability,
    reopen_stage,
    encode(sha256(convert_to(canonical_inputs.value::text, 'UTF8')), 'hex') AS fingerprint,
    jsonb_build_object(
      'engine_version', 'probability-v1',
      'evaluated_at', requested_evaluated_at,
      'stage', jsonb_build_object('name', reopen_stage, 'base', reopen_base, 'ceiling', reopen_ceiling),
      'terminal_kind', NULL,
      'primary', jsonb_build_object(
        'source_account', source_username, 'independence_key', independence_key,
        'reliability', reliability, 'wording_factor', reopen_wording_factor,
        'recency_factor', reopen_recency_factor, 'adjustment', primary_adjustment
      ),
      'corroboration', '[]'::jsonb,
      'contradictions', '[]'::jsonb,
      'story_staleness_adjustment', 0,
      'raw_probability', round(final_probability, 5),
      'normalized_probability', round(final_probability, 5),
      'normalization', 'pending-stage-5'
    ) AS details
  FROM reopen_result CROSS JOIN canonical_inputs
)
SELECT base.raw_probability, base.normalized_probability, base.current_stage,
  base.explanation, base.input_fingerprint
FROM base
WHERE NOT EXISTS (SELECT 1 FROM reopen_output)
UNION ALL
SELECT reopen_output.final_probability, reopen_output.final_probability,
  reopen_output.reopen_stage, reopen_output.details, reopen_output.fingerprint
FROM reopen_output
UNION ALL
SELECT contradiction_output.final_probability, contradiction_output.final_probability,
  'link', contradiction_output.details, contradiction_output.fingerprint
FROM contradiction_output;
$$;

CREATE OR REPLACE FUNCTION settle_expired_probability_v1_cases(
  requested_mode text,
  requested_evaluated_at timestamptz,
  requested_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE selected_case record; changed_sources bigint[];
  all_changed_sources bigint[] := '{}'::bigint[];
  batch_count integer; processed integer := 0;
BEGIN
  IF requested_mode NOT IN ('shadow', 'active') THEN RETURN 0; END IF;
  IF requested_limit <= 0 THEN RETURN 0; END IF;

  LOOP
    batch_count := 0;
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
      LIMIT LEAST(requested_limit, 100)
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
      batch_count := batch_count + 1;
    END LOOP;
    EXIT WHEN batch_count = 0;
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
