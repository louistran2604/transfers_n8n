ALTER TABLE transfer_reports
  DROP CONSTRAINT transfer_reports_probability_status_check;

ALTER TABLE transfer_reports
  ADD CONSTRAINT transfer_reports_probability_status_check
  CHECK (probability_status IN ('legacy_unscored', 'shadow_scored', 'active_scored'));

CREATE OR REPLACE FUNCTION app_set_probability_status()
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

CREATE FUNCTION promote_probability_v1_case(
  requested_transfer_case_id bigint,
  requested_evaluated_at timestamptz
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  previous_leader_id bigint;
  current_leader_id bigint;
  leader_changed boolean;
  promoted_count integer;
BEGIN
  SELECT revision.transfer_report_id
  INTO previous_leader_id
  FROM (
    SELECT DISTINCT ON (candidate.transfer_report_id) candidate.*
    FROM transfer_probability_revisions candidate
    WHERE candidate.transfer_case_id = requested_transfer_case_id
      AND candidate.evaluated_at = requested_evaluated_at
    ORDER BY candidate.transfer_report_id, candidate.revision_number DESC, candidate.id DESC
  ) revision
  WHERE revision.previous_probability IS NOT NULL
  ORDER BY revision.previous_probability DESC, revision.transfer_report_id
  LIMIT 1;

  SELECT report.id
  INTO current_leader_id
  FROM transfer_reports report
  WHERE report.transfer_case_id = requested_transfer_case_id
  ORDER BY report.normalized_probability DESC NULLS LAST, report.id
  LIMIT 1;

  leader_changed := previous_leader_id IS NOT NULL
    AND previous_leader_id IS DISTINCT FROM current_leader_id;

  WITH current_probability AS (
    SELECT DISTINCT ON (revision.transfer_report_id)
      revision.*,
      CASE revision.explanation->>'terminal_kind'
        WHEN 'official_confirmation' THEN 'official'
        WHEN 'authoritative_collapse' THEN 'collapsed'
        ELSE 'open'
      END AS terminal_state
    FROM transfer_probability_revisions revision
    WHERE revision.transfer_case_id = requested_transfer_case_id
      AND revision.engine_version = 'probability-v1'
    ORDER BY revision.transfer_report_id, revision.revision_number DESC
  ), previous_probability AS (
    SELECT current.transfer_report_id,
      previous.current_stage,
      CASE previous.explanation->>'terminal_kind'
        WHEN 'official_confirmation' THEN 'official'
        WHEN 'authoritative_collapse' THEN 'collapsed'
        ELSE 'open'
      END AS terminal_state
    FROM current_probability current
    LEFT JOIN transfer_probability_revisions previous
      ON previous.transfer_report_id = current.transfer_report_id
     AND previous.engine_version = current.engine_version
     AND previous.revision_number = current.revision_number - 1
  ), candidates AS (
    SELECT current.*,
      previous.current_stage AS previous_stage,
      previous.terminal_state AS previous_terminal_state,
      latest_material.snapshot AS base_snapshot,
      latest_material.snapshot->>'probability_status' IS DISTINCT FROM 'active_scored'
        AS latest_material_is_not_active
    FROM transfer_reports report
    JOIN current_probability current ON current.transfer_report_id = report.id
    LEFT JOIN previous_probability previous ON previous.transfer_report_id = report.id
    JOIN LATERAL (
      SELECT material.snapshot
      FROM transfer_report_revisions material
      WHERE material.transfer_report_id = report.id
      ORDER BY material.revision_number DESC, material.id DESC
      LIMIT 1
    ) latest_material ON true
    WHERE report.transfer_case_id = requested_transfer_case_id
  ), snapshots AS (
    SELECT candidates.*,
      (base_snapshot - 'probability' - 'probability_status') || jsonb_build_object(
        'probability_status', 'active_scored',
        'probability', jsonb_build_object(
          'engine_version', engine_version,
          'normalized_probability', normalized_probability,
          'previous_probability', previous_probability,
          'probability_delta', probability_delta,
          'current_stage', current_stage,
          'terminal_state', terminal_state,
          'is_leading_destination', transfer_report_id = current_leader_id,
          'leading_destination_changed', leader_changed,
          'explanation', explanation
        )
      ) AS snapshot
    FROM candidates
    WHERE latest_material_is_not_active
      OR current_stage IS DISTINCT FROM previous_stage
      OR terminal_state IS DISTINCT FROM previous_terminal_state
      OR abs(COALESCE(probability_delta, 0)) >= 0.05
      OR leader_changed
  ), inserted AS (
    INSERT INTO transfer_report_revisions (
      transfer_report_id, revision_number, content_sha256, snapshot
    )
    SELECT transfer_report_id,
      COALESCE((SELECT max(existing.revision_number) + 1
        FROM transfer_report_revisions existing
        WHERE existing.transfer_report_id = snapshots.transfer_report_id), 1),
      encode(sha256(convert_to(snapshot::text, 'UTF8')), 'hex'),
      snapshot
    FROM snapshots
    ON CONFLICT (transfer_report_id, content_sha256) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO promoted_count FROM inserted;

  UPDATE transfer_reports
  SET probability_status = 'active_scored'
  WHERE transfer_case_id = requested_transfer_case_id
    AND probability_engine_version = 'probability-v1'
    AND normalized_probability IS NOT NULL;

  RETURN promoted_count;
END;
$$;

CREATE FUNCTION apply_probability_v1_active(
  requested_transfer_report_id bigint,
  payload jsonb
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  probability_revision_id bigint;
  requested_transfer_case_id bigint;
BEGIN
  IF payload->>'probability_mode' IS DISTINCT FROM 'active' THEN RETURN NULL; END IF;

  probability_revision_id := apply_probability_v1_shadow(
    requested_transfer_report_id,
    jsonb_set(payload, '{probability_mode}', '"shadow"'::jsonb)
  );

  SELECT transfer_case_id INTO requested_transfer_case_id
  FROM transfer_reports WHERE id = requested_transfer_report_id;
  PERFORM promote_probability_v1_case(
    requested_transfer_case_id,
    (payload->>'evaluated_at')::timestamptz
  );
  UPDATE transfer_reports
  SET probability_status = 'active_scored'
  WHERE transfer_case_id = requested_transfer_case_id
    AND probability_engine_version = 'probability-v1'
    AND normalized_probability IS NOT NULL;
  RETURN probability_revision_id;
END;
$$;

CREATE FUNCTION sync_transfer_case_probability_status()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  UPDATE transfer_cases transfer_case
  SET status = CASE
    WHEN EXISTS (
      SELECT 1 FROM transfer_reports report
      WHERE report.transfer_case_id = transfer_case.id
        AND report.probability_explanation->>'terminal_kind' = 'official_confirmation'
    ) THEN 'completed'
    WHEN NOT EXISTS (
      SELECT 1 FROM transfer_reports report
      WHERE report.transfer_case_id = transfer_case.id
        AND report.transfer_stage IS DISTINCT FROM 'collapsed'
        AND report.probability_explanation->>'terminal_kind' IS DISTINCT FROM 'authoritative_collapse'
    ) THEN 'collapsed'
    ELSE 'open'
  END
  FROM (SELECT DISTINCT transfer_case_id FROM new_probability_reports) changed
  WHERE transfer_case.id = changed.transfer_case_id
    AND transfer_case.status <> 'closed';
  RETURN NULL;
END;
$$;

CREATE TRIGGER transfer_reports_sync_probability_case_status_after_insert
AFTER INSERT ON transfer_reports
REFERENCING NEW TABLE AS new_probability_reports
FOR EACH STATEMENT EXECUTE FUNCTION sync_transfer_case_probability_status();

CREATE TRIGGER transfer_reports_sync_probability_case_status_after_update
AFTER UPDATE ON transfer_reports
REFERENCING NEW TABLE AS new_probability_reports
FOR EACH STATEMENT EXECUTE FUNCTION sync_transfer_case_probability_status();

CREATE FUNCTION probability_v1_stale_cases(
  requested_evaluated_at timestamptz,
  requested_limit integer DEFAULT 100
)
RETURNS TABLE (transfer_case_id bigint)
LANGUAGE sql
VOLATILE
AS $$
  WITH candidate AS (
    SELECT transfer_case.id AS transfer_case_id,
      newest.posted_at,
      newest.half_life_days,
      max(report.probability_updated_at) AS last_evaluated_at
    FROM transfer_cases transfer_case
    JOIN transfer_reports report ON report.transfer_case_id = transfer_case.id
    JOIN LATERAL (
      SELECT post.posted_at,
        CASE
          WHEN evidence.claim_stance = 'contradicts'
            OR evidence.club_agreement_state IN ('rejected', 'collapsed')
            OR evidence.personal_terms_state = 'rejected'
            OR evidence.stage_signal IN ('setback', 'collapsed') THEN 14
          WHEN evidence.stage_signal IN ('link', 'interest') THEN 7
          WHEN evidence.stage_signal IN ('agreed', 'done', 'official_wording')
            OR evidence.completion_claim <> 'none' THEN 30
          ELSE 14
        END::numeric AS half_life_days
      FROM transfer_evidence evidence
      JOIN raw_posts post ON post.id = evidence.raw_post_id
      WHERE evidence.transfer_case_id = transfer_case.id
        AND evidence.extraction_confidence >= 0.50
      ORDER BY post.posted_at DESC, post.id DESC, evidence.id DESC
      LIMIT 1
    ) newest ON true
    WHERE transfer_case.status = 'open'
      AND report.probability_status IN ('shadow_scored', 'active_scored')
    GROUP BY transfer_case.id, newest.posted_at, newest.half_life_days
  ), eligible AS (
    SELECT transfer_case.id AS transfer_case_id
    FROM transfer_cases transfer_case
    JOIN candidate ON candidate.transfer_case_id = transfer_case.id
    WHERE transfer_case.status = 'open'
      AND candidate.last_evaluated_at <
        candidate.posted_at + candidate.half_life_days * interval '1 day'
      AND requested_evaluated_at >=
        candidate.posted_at + candidate.half_life_days * interval '1 day'
    ORDER BY transfer_case.id
    FOR UPDATE OF transfer_case SKIP LOCKED
    LIMIT LEAST(GREATEST(requested_limit, 0), 100)
  )
  SELECT transfer_case_id FROM eligible ORDER BY transfer_case_id;
$$;

CREATE FUNCTION recompute_stale_probability_v1_cases(
  requested_mode text,
  requested_evaluated_at timestamptz,
  requested_limit integer DEFAULT 100
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  selected_case record;
  selected_report_id bigint;
  payload jsonb;
  processed integer := 0;
BEGIN
  IF requested_mode NOT IN ('shadow', 'active') THEN RETURN 0; END IF;

  FOR selected_case IN
    SELECT transfer_case_id
    FROM probability_v1_stale_cases(requested_evaluated_at, requested_limit)
  LOOP
    SELECT report.id,
      jsonb_build_object(
        'probability_mode', requested_mode,
        'evaluated_at', requested_evaluated_at,
        'destination_club_name', report.destination_club_name,
        'normalized_data', jsonb_build_object(
          'current_club_key', COALESCE(transfer_case.normalized_current_club, 'unknown')
        ),
        'sources', jsonb_build_array(jsonb_build_object(
          'raw_post_id', evidence.raw_post_id,
          'posted_at', post.posted_at,
          'report_ordinal', evidence.report_ordinal,
          'extraction_schema_version', evidence.extraction_schema_version,
          'normalized_evidence', evidence.raw_normalized_extraction - '_resolved_source'
        ))
      )
    INTO selected_report_id, payload
    FROM transfer_reports report
    JOIN transfer_cases transfer_case ON transfer_case.id = report.transfer_case_id
    JOIN LATERAL (
      SELECT evidence.*
      FROM transfer_evidence evidence
      WHERE evidence.transfer_report_id = report.id
      ORDER BY evidence.created_at, evidence.id
      LIMIT 1
    ) evidence ON true
    JOIN raw_posts post ON post.id = evidence.raw_post_id
    WHERE report.transfer_case_id = selected_case.transfer_case_id
      AND transfer_case.status = 'open'
      AND report.probability_status IN ('shadow_scored', 'active_scored')
    ORDER BY report.id
    LIMIT 1;

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
