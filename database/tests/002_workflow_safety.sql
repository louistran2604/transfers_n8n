\set ON_ERROR_STOP on

BEGIN;

SELECT CASE WHEN EXISTS (
  SELECT 1 FROM app_schema_migrations WHERE version = '001_initial_schema'
) THEN 'true' ELSE 'false' END AS migration_ready \gset
\if :migration_ready
\else
  \echo 'Migration 001_initial_schema has not been applied'
  \quit 3
\endif

-- Repeating this conflict-safe source upsert models concurrent collectors that
-- observe the same configured source. The unique external ID leaves one row.
INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank, reliability_score
) VALUES (
  '900000000000000201', 'workflowsafety', 'Workflow Safety Source', 'individual', 4, 0.700
)
ON CONFLICT (platform, external_account_id) DO UPDATE
SET display_name = EXCLUDED.display_name
RETURNING id \gset

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank, reliability_score
) VALUES (
  '900000000000000201', 'workflowsafety', 'Workflow Safety Source', 'individual', 4, 0.700
)
ON CONFLICT (platform, external_account_id) DO UPDATE
SET display_name = EXCLUDED.display_name;

INSERT INTO raw_posts (
  source_account_id, external_post_id, post_url, content, posted_at, raw_payload
) VALUES (
  :id, '900000000000000202', 'https://x.com/workflowsafety/status/900000000000000202',
  'Workflow safety fixture.', '2026-07-26 06:00:00+00', '{}'::jsonb
)
ON CONFLICT (platform, external_post_id) DO UPDATE
SET collected_at = CURRENT_TIMESTAMP
RETURNING id \gset raw_post_

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('workflow-safety-player', 'Workflow Safety Player', 'workflow safety player')
ON CONFLICT (identity_key) DO UPDATE SET display_name = EXCLUDED.display_name
RETURNING id \gset player_

INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, classification, confidence, first_reported_at, last_reported_at
) VALUES (
  'workflow-safety-player|unknown|unknown', :player_id, 'Workflow Safety Player',
  'rumor', 0.500, '2026-07-26 06:00:00+00', '2026-07-26 06:00:00+00'
)
ON CONFLICT (dedupe_key) DO UPDATE SET last_reported_at = EXCLUDED.last_reported_at
RETURNING id \gset report_

INSERT INTO raw_posts (
  source_account_id, external_post_id, post_url, content, posted_at, raw_payload
) VALUES (
  :id, '900000000000000203', 'https://x.com/workflowsafety/status/900000000000000203',
  'Workflow safety replacement source fixture.', '2026-07-26 06:01:00+00', '{}'::jsonb
)
ON CONFLICT (platform, external_post_id) DO UPDATE
SET collected_at = CURRENT_TIMESTAMP
RETURNING id \gset replacement_raw_post_

-- Preferred-source replacement must happen in two ordered statements. A single
-- data-modifying CTE can attempt the new preferred insert before clearing the old
-- row, which violates the partial unique index.
INSERT INTO transfer_report_sources (
  transfer_report_id, raw_post_id, source_observed_at, is_preferred
) VALUES (:report_id, :raw_post_id, '2026-07-26 06:00:00+00', true)
ON CONFLICT (transfer_report_id, raw_post_id) DO UPDATE
SET source_observed_at = EXCLUDED.source_observed_at,
    is_preferred = true;

INSERT INTO transfer_report_sources (
  transfer_report_id, raw_post_id, source_observed_at, is_preferred
) VALUES (:report_id, :replacement_raw_post_id, '2026-07-26 06:01:00+00', false)
ON CONFLICT (transfer_report_id, raw_post_id) DO UPDATE
SET source_observed_at = EXCLUDED.source_observed_at,
    is_preferred = false;

UPDATE transfer_report_sources
SET is_preferred = false
WHERE transfer_report_id = :report_id AND is_preferred;

UPDATE transfer_report_sources
SET is_preferred = true
WHERE transfer_report_id = :report_id AND raw_post_id = :replacement_raw_post_id;

INSERT INTO transfer_report_revisions (
  transfer_report_id, revision_number, content_sha256, snapshot
) VALUES (
  :report_id, 1, 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  '{"classification":"rumor","confidence":0.5}'::jsonb
)
ON CONFLICT (transfer_report_id, content_sha256) DO NOTHING
RETURNING id \gset revision_

-- A replay with the same material snapshot must not add a revision.
INSERT INTO transfer_report_revisions (
  transfer_report_id, revision_number, content_sha256, snapshot
) VALUES (
  :report_id, 2, 'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
  '{"classification":"rumor","confidence":0.5}'::jsonb
)
ON CONFLICT (transfer_report_id, content_sha256) DO NOTHING;

INSERT INTO digest_deliveries (
  idempotency_key, channel_key, window_started_at, window_ended_at, status, attempt_count
) VALUES (
  'transfer-digest|2026-07-26T06:00:00Z', 'transfers',
  '2026-07-26 06:00:00+00', '2026-07-26 12:00:00+00', 'sending', 1
)
RETURNING id \gset delivery_

INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
VALUES (:delivery_id, :revision_id, 1)
ON CONFLICT (transfer_report_revision_id) DO NOTHING;

-- Recovery intentionally makes an interrupted request unknown. It must not
-- create another delivery or free the already reserved revision for resend.
UPDATE digest_deliveries SET status = 'unknown' WHERE status = 'sending';

INSERT INTO retry_states (
  resource_type, resource_key, operation_name, state, attempt_count, next_attempt_at
) VALUES (
  'raw_post', 'x:900000000000000202', 'qwen_extract', 'retrying', 1,
  '2026-07-26 06:00:01+00'
)
ON CONFLICT (resource_type, resource_key, operation_name) DO UPDATE
SET state = 'retrying', attempt_count = retry_states.attempt_count + 1,
    next_attempt_at = EXCLUDED.next_attempt_at
RETURNING id \gset retry_state_

INSERT INTO retry_states (
  resource_type, resource_key, operation_name, state, attempt_count, next_attempt_at
) VALUES (
  'raw_post', 'x:900000000000000202', 'qwen_extract', 'retrying', 1,
  '2026-07-26 06:00:02+00'
)
ON CONFLICT (resource_type, resource_key, operation_name) DO UPDATE
SET state = 'retrying', attempt_count = retry_states.attempt_count + 1,
    next_attempt_at = EXCLUDED.next_attempt_at;

INSERT INTO workflow_runs (
  workflow_name, external_execution_id, logical_run_key, attempt_number, status
) VALUES (
  'football-transfer-monitor', 'workflow-safety-first', '2026-07-26T06:00:00Z', 1, 'failed'
), (
  'football-transfer-monitor', 'workflow-safety-replay', '2026-07-26T06:00:00Z', 2, 'running'
);

SELECT CASE
  WHEN (SELECT count(*) FROM source_accounts WHERE external_account_id = '900000000000000201') = 1
   AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :report_id) = 1
   AND (SELECT status FROM digest_deliveries WHERE id = :delivery_id) = 'unknown'
   AND (SELECT count(*) FROM digest_items WHERE transfer_report_revision_id = :revision_id) = 1
   AND (SELECT attempt_count FROM retry_states WHERE id = :retry_state_id) = 2
   AND (SELECT count(*) FROM workflow_runs WHERE workflow_name = 'football-transfer-monitor' AND logical_run_key = '2026-07-26T06:00:00Z') = 2
   AND (SELECT count(*) FROM transfer_report_sources WHERE transfer_report_id = :report_id AND is_preferred) = 1
   AND (SELECT raw_post_id FROM transfer_report_sources WHERE transfer_report_id = :report_id AND is_preferred) = :replacement_raw_post_id
  THEN 'true' ELSE 'false'
END AS workflow_safety \gset

\if :workflow_safety
\else
  \echo 'Workflow idempotency, revision, retry, or interrupted-delivery assertion failed'
  \quit 3
\endif

ROLLBACK;
