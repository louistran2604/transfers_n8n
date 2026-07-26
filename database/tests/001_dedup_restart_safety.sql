\set ON_ERROR_STOP on

BEGIN;

SELECT CASE
  WHEN EXISTS (
    SELECT 1 FROM app_schema_migrations WHERE version = '001_initial_schema'
  ) THEN 'true'
  ELSE 'false'
END AS migration_ready \gset

\if :migration_ready
\else
  \echo 'Migration 001_initial_schema has not been applied'
  \quit 3
\endif

INSERT INTO source_accounts (
  external_account_id,
  username,
  display_name,
  account_type,
  priority_rank,
  reliability_score
)
VALUES (
  '900000000000000001',
  'dedupsource',
  'Deduplication Test Source',
  'individual',
  4,
  0.900
)
ON CONFLICT (platform, external_account_id) DO UPDATE
SET display_name = EXCLUDED.display_name
RETURNING id \gset

INSERT INTO raw_posts (
  source_account_id,
  external_post_id,
  post_url,
  content,
  content_sha256,
  posted_at
)
VALUES (
  :id,
  '900000000000000101',
  'https://x.com/dedupsource/status/900000000000000101',
  'Deduplication test transfer report.',
  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  '2026-07-26 00:00:00+00'
)
ON CONFLICT (platform, external_post_id) DO UPDATE
SET collected_at = CURRENT_TIMESTAMP
RETURNING id \gset raw_post_

INSERT INTO raw_posts (
  source_account_id,
  external_post_id,
  post_url,
  content,
  content_sha256,
  posted_at
)
VALUES (
  :id,
  '900000000000000102',
  'https://x.com/dedupsource/status/900000000000000102',
  'Second supporting source for the same transfer.',
  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  '2026-07-26 00:01:00+00'
)
ON CONFLICT (platform, external_post_id) DO UPDATE
SET collected_at = CURRENT_TIMESTAMP
RETURNING id \gset second_raw_post_

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('test-player-001', 'Test Player', 'test player')
ON CONFLICT (identity_key) DO UPDATE
SET display_name = EXCLUDED.display_name
RETURNING id \gset player_

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
  'test-player-001|test-fc|destination-fc',
  :player_id,
  'Test Player',
  'Test FC',
  'Destination FC',
  'rumor',
  0.800,
  '2026-07-26 00:00:00+00',
  '2026-07-26 00:00:00+00'
)
ON CONFLICT (dedupe_key) DO UPDATE
SET last_reported_at = EXCLUDED.last_reported_at
RETURNING id \gset report_

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
  'test-player-001|test-fc|destination-fc',
  :player_id,
  'Test Player',
  'Test FC',
  'Destination FC',
  'rumor',
  0.800,
  '2026-07-26 00:00:00+00',
  '2026-07-26 00:00:00+00'
)
ON CONFLICT (dedupe_key) DO UPDATE
SET last_reported_at = EXCLUDED.last_reported_at
RETURNING id \gset report_retry_

INSERT INTO transfer_report_sources (
  transfer_report_id,
  raw_post_id,
  source_observed_at,
  is_preferred
)
VALUES (:report_id, :raw_post_id, '2026-07-26 00:00:00+00', true)
ON CONFLICT (transfer_report_id, raw_post_id) DO UPDATE
SET source_observed_at = EXCLUDED.source_observed_at
RETURNING id \gset report_source_

INSERT INTO transfer_report_sources (
  transfer_report_id,
  raw_post_id,
  source_observed_at,
  is_preferred
)
VALUES (:report_id, :raw_post_id, '2026-07-26 00:00:00+00', true)
ON CONFLICT (transfer_report_id, raw_post_id) DO UPDATE
SET source_observed_at = EXCLUDED.source_observed_at
RETURNING id \gset report_source_retry_

INSERT INTO transfer_report_sources (
  transfer_report_id,
  raw_post_id,
  source_observed_at,
  is_preferred
)
VALUES (
  :report_id,
  :second_raw_post_id,
  '2026-07-26 00:01:00+00',
  true
)
ON CONFLICT (transfer_report_id) WHERE is_preferred DO NOTHING;

INSERT INTO transfer_report_sources (
  transfer_report_id,
  raw_post_id,
  source_observed_at,
  is_preferred
)
VALUES (
  :report_id,
  :second_raw_post_id,
  '2026-07-26 00:01:00+00',
  false
)
ON CONFLICT (transfer_report_id, raw_post_id) DO UPDATE
SET source_observed_at = EXCLUDED.source_observed_at;

INSERT INTO transfer_report_revisions (
  transfer_report_id,
  revision_number,
  content_sha256,
  snapshot
)
VALUES (
  :report_id,
  1,
  'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
  '{"classification":"rumor","confidence":0.8}'::jsonb
)
ON CONFLICT (transfer_report_id, content_sha256) DO NOTHING
RETURNING id \gset revision_

INSERT INTO digest_deliveries (
  idempotency_key,
  channel_key,
  window_started_at,
  window_ended_at
)
VALUES (
  'transfer-digest|2026-07-26T00:00:00Z',
  'transfers',
  '2026-07-26 00:00:00+00',
  '2026-07-26 06:00:00+00'
)
ON CONFLICT (idempotency_key) DO UPDATE
SET updated_at = CURRENT_TIMESTAMP
RETURNING id \gset delivery_

INSERT INTO digest_deliveries (
  idempotency_key,
  channel_key,
  window_started_at,
  window_ended_at
)
VALUES (
  'transfer-digest|2026-07-26T00:00:00Z',
  'transfers',
  '2026-07-26 00:00:00+00',
  '2026-07-26 06:00:00+00'
)
ON CONFLICT (idempotency_key) DO UPDATE
SET updated_at = CURRENT_TIMESTAMP
RETURNING id \gset delivery_retry_

INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
VALUES (:delivery_id, :revision_id, 1)
ON CONFLICT (transfer_report_revision_id) DO NOTHING;

INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
VALUES (:delivery_id, :revision_id, 1)
ON CONFLICT (transfer_report_revision_id) DO NOTHING;

INSERT INTO workflow_runs (
  workflow_name,
  external_execution_id,
  logical_run_key,
  attempt_number,
  status
)
VALUES ('transfer-digest', 'n8n-test-execution-001', '2026-07-26T00:00:00Z', 1, 'running')
ON CONFLICT (workflow_name, external_execution_id) DO UPDATE
SET status = EXCLUDED.status
RETURNING id \gset workflow_run_

INSERT INTO retry_states (
  resource_type,
  resource_key,
  operation_name,
  state,
  attempt_count,
  next_attempt_at
)
VALUES (
  'raw_post',
  'x:900000000000000101',
  'classify',
  'retrying',
  1,
  '2026-07-26 00:05:00+00'
)
ON CONFLICT (resource_type, resource_key, operation_name) DO UPDATE
SET attempt_count = retry_states.attempt_count + 1,
    next_attempt_at = EXCLUDED.next_attempt_at
RETURNING id \gset retry_state_

INSERT INTO retry_states (
  resource_type,
  resource_key,
  operation_name,
  state,
  attempt_count,
  next_attempt_at
)
VALUES (
  'raw_post',
  'x:900000000000000101',
  'classify',
  'retrying',
  1,
  '2026-07-26 00:05:00+00'
)
ON CONFLICT (resource_type, resource_key, operation_name) DO UPDATE
SET attempt_count = retry_states.attempt_count + 1,
    next_attempt_at = EXCLUDED.next_attempt_at
RETURNING id \gset retry_state_retry_

SELECT CASE
  WHEN :report_id = :report_retry_id
   AND :report_source_id = :report_source_retry_id
   AND :delivery_id = :delivery_retry_id
   AND (SELECT count(*) FROM transfer_reports WHERE dedupe_key = 'test-player-001|test-fc|destination-fc') = 1
   AND (SELECT count(*) FROM transfer_report_sources WHERE transfer_report_id = :report_id) = 2
   AND (SELECT count(*) FROM transfer_report_sources WHERE transfer_report_id = :report_id AND is_preferred) = 1
   AND (SELECT count(*) FROM digest_items WHERE transfer_report_revision_id = :revision_id) = 1
   AND (SELECT attempt_count FROM retry_states WHERE id = :retry_state_id) = 2
  THEN 'true'
  ELSE 'false'
END AS restart_safe \gset

\if :restart_safe
\else
  \echo 'Deduplication or restart-safety assertion failed'
  \quit 3
\endif

ROLLBACK;
