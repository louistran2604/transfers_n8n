\set ON_ERROR_STOP on

BEGIN;

SELECT CASE
  WHEN (
    SELECT count(*)
    FROM app_schema_migrations
    WHERE version IN ('001_initial_schema', '002_soccerdata_enrichment')
  ) = 2
  THEN 'true'
  ELSE 'false'
END AS migrations_ready \gset

\if :migrations_ready
\else
  \echo 'Migrations 001 and 002 are required for rollback compatibility'
  \quit 3
\endif

-- These writes use only the pre-feature columns and queries.
INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('rollback-player', 'Rollback Player', 'rollback player')
RETURNING id \gset rollback_player_

INSERT INTO transfer_reports (
  dedupe_key,
  player_id,
  reported_player_name,
  current_club_name,
  destination_club_name,
  classification,
  confidence,
  first_reported_at,
  last_reported_at
)
VALUES (
  'rollback-player|old-fc|new-fc',
  :rollback_player_id,
  'Rollback Player',
  'Old FC',
  'New FC',
  'rumor',
  0.750,
  '2026-07-30 00:00:00+00',
  '2026-07-30 00:00:00+00'
)
RETURNING id \gset rollback_report_

INSERT INTO transfer_report_revisions (
  transfer_report_id,
  revision_number,
  content_sha256,
  snapshot
)
VALUES (
  :rollback_report_id,
  1,
  repeat('a', 64),
  '{"classification":"rumor"}'::jsonb
)
RETURNING id \gset rollback_revision_

INSERT INTO digest_deliveries (
  idempotency_key,
  channel_key,
  window_started_at,
  window_ended_at
)
VALUES (
  'rollback-compatible-delivery',
  'transfers',
  '2026-07-30 00:00:00+00',
  '2026-07-30 06:00:00+00'
)
RETURNING id \gset rollback_delivery_

INSERT INTO digest_items (
  digest_delivery_id,
  transfer_report_revision_id,
  position
)
VALUES (
  :rollback_delivery_id,
  :rollback_revision_id,
  1
);

UPDATE digest_deliveries
SET
  status = 'sending',
  attempt_count = attempt_count + 1,
  first_attempted_at = COALESCE(first_attempted_at, CURRENT_TIMESTAMP),
  last_attempted_at = CURRENT_TIMESTAMP
WHERE id = :rollback_delivery_id
  AND status = 'pending';

UPDATE digest_deliveries
SET status = 'unknown'
WHERE id = :rollback_delivery_id
  AND status = 'sending';

SELECT CASE
  WHEN (
    SELECT request_payload = '{}'::jsonb
    FROM digest_deliveries
    WHERE id = :rollback_delivery_id
  )
   AND (
     SELECT status = 'unknown'
       AND attempt_count = 1
       AND discord_message_id IS NULL
     FROM digest_deliveries
     WHERE id = :rollback_delivery_id
   )
   AND (
     SELECT count(*)
     FROM digest_items
     WHERE digest_delivery_id = :rollback_delivery_id
   ) = 1
   AND (
     SELECT count(*)
     FROM transfer_report_revisions
     WHERE transfer_report_id = :rollback_report_id
   ) = 1
   AND NOT EXISTS (
     SELECT 1
     FROM transfer_report_player_resolutions
     WHERE transfer_report_id = :rollback_report_id
   )
  THEN 'true'
  ELSE 'false'
END AS rollback_compatible \gset

\if :rollback_compatible
\else
  \echo 'Pre-feature merge/revision/reservation/recovery compatibility failed'
  \quit 3
\endif

ROLLBACK;
