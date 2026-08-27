CREATE FUNCTION project_transfer_fee_context(
  requested_at timestamptz DEFAULT CURRENT_TIMESTAMP,
  requested_window_started_at timestamptz DEFAULT NULL,
  requested_window_ended_at timestamptz DEFAULT NULL
)
RETURNS integer
LANGUAGE plpgsql
AS $$
DECLARE
  inserted_count integer;
BEGIN
  -- ponytail: one ordered lock set; add bounded writer-coordinated claims if lock duration becomes measurable.
  PERFORM report.id
  FROM transfer_reports report
  JOIN current_player_enrichment enrichment
    ON enrichment.transfer_report_id = report.id
   AND enrichment.profile_snapshot_id IS NOT NULL
  ORDER BY report.id
  FOR UPDATE OF report;

  WITH latest_revisions AS (
    SELECT report.id AS transfer_report_id,
      latest.id AS revision_id,
      latest.snapshot,
      latest.revision_number,
      latest.created_at
    FROM transfer_reports report
    JOIN LATERAL (
      SELECT revision.id, revision.snapshot, revision.revision_number, revision.created_at
      FROM transfer_report_revisions revision
      WHERE revision.transfer_report_id = report.id
      ORDER BY revision.revision_number DESC, revision.id DESC
      LIMIT 1
    ) latest ON true
    JOIN current_player_enrichment enrichment
      ON enrichment.transfer_report_id = report.id
     AND enrichment.profile_snapshot_id IS NOT NULL
    WHERE NOT EXISTS (
      SELECT 1 FROM digest_items item
      WHERE item.transfer_report_revision_id = latest.id
    )
      AND (requested_window_started_at IS NULL
        OR latest.created_at >= requested_window_started_at)
      AND (requested_window_ended_at IS NULL
        OR latest.created_at <= requested_window_ended_at)
  ), contexts AS (
    SELECT latest.*,
      jsonb_build_object(
        'profile_snapshot_id', enrichment.profile_snapshot_id::text,
        'market_value', enrichment.market_value,
        'market_value_currency', enrichment.market_value_currency,
        'market_value_as_of', enrichment.profile_retrieved_at,
        'stale', enrichment.profile_fresh_until <= requested_at
      ) || jsonb_strip_nulls(jsonb_build_object(
        'guaranteed_fee_ratio', CASE
          WHEN enrichment.profile_fresh_until > requested_at
            AND (latest.snapshot->>'fee_amount')::numeric IS NOT NULL
            AND enrichment.market_value > 0
            AND latest.snapshot->>'fee_currency' = enrichment.market_value_currency
          THEN (latest.snapshot->>'fee_amount')::numeric / enrichment.market_value
        END,
        'fee_plus_add_ons_ratio', CASE
          WHEN enrichment.profile_fresh_until > requested_at
            AND (latest.snapshot->>'fee_amount')::numeric IS NOT NULL
            AND (latest.snapshot->>'add_ons_amount')::numeric IS NOT NULL
            AND enrichment.market_value > 0
            AND latest.snapshot->>'fee_currency' = enrichment.market_value_currency
            AND latest.snapshot->>'add_ons_currency' = enrichment.market_value_currency
          THEN ((latest.snapshot->>'fee_amount')::numeric
            + (latest.snapshot->>'add_ons_amount')::numeric) / enrichment.market_value
        END
      )) AS fee_context
    FROM latest_revisions latest
    JOIN current_player_enrichment enrichment
      ON enrichment.transfer_report_id = latest.transfer_report_id
    WHERE enrichment.profile_snapshot_id IS NOT NULL
  ), snapshots AS (
    SELECT contexts.*,
      snapshot || jsonb_build_object('fee_context', fee_context) AS enriched_snapshot
    FROM contexts
    WHERE snapshot->'fee_context' IS DISTINCT FROM fee_context
  ), inserted AS (
    INSERT INTO transfer_report_revisions (
      transfer_report_id, revision_number, content_sha256, snapshot
    )
    SELECT transfer_report_id, revision_number + 1,
      encode(sha256(convert_to(enriched_snapshot::text, 'UTF8')), 'hex'),
      enriched_snapshot
    FROM snapshots
    ON CONFLICT (transfer_report_id, content_sha256) DO NOTHING
    RETURNING 1
  )
  SELECT count(*) INTO inserted_count FROM inserted;
  RETURN inserted_count;
END;
$$;
