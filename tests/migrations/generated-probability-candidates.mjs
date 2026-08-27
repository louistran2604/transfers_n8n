#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';

const output = process.argv[2];
if (!output) throw new Error('Usage: generated-probability-candidates.mjs OUTPUT.sql');

const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
const node = workflow.nodes.find((candidate) => candidate.name === 'Find undelivered revisions');
if (!node?.parameters?.query) throw new Error('Generated candidates query not found');

const hash = (value) => value.repeat(64);
const sql = `\\set ON_ERROR_STOP on
BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END;
$$;

-- Earlier migration fixtures may leave an unrelated pending delivery behind.
-- Isolate the fresh-candidate assertions while keeping every change transactional.
UPDATE digest_deliveries
SET status = 'sent', sent_at = COALESCE(sent_at, CURRENT_TIMESTAMP)
WHERE status = 'pending';

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('996000000000000001', 'candfixture', 'Candidate Fixture', 'individual', 1,
  0.800, 0.800, 'reporter:candidate-fixture', 'journalist')
RETURNING id AS source_id \\gset

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('candidate-fixture', 'Candidate Fixture', 'candidate fixture')
RETURNING id AS player_id \\gset

INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('candidate-fixture|old|2026-H2', :player_id, 'old', '2026-H2')
RETURNING id AS case_id \\gset

INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name,
  destination_club_name, classification, move_type, confidence,
  first_reported_at, last_reported_at, transfer_case_id
) VALUES
  ('candidate-active', :player_id, 'Candidate Fixture', 'Old FC', 'Active FC',
    'rumor', 'permanent', 0.7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, :case_id),
  ('candidate-legacy', :player_id, 'Candidate Fixture', 'Old FC', 'Legacy FC',
    'rumor', 'permanent', 0.7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, :case_id),
  ('candidate-pending', :player_id, 'Candidate Fixture', 'Old FC', 'Pending FC',
    'rumor', 'permanent', 0.7, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, :case_id);
SELECT id AS active_report_id FROM transfer_reports WHERE dedupe_key = 'candidate-active' \\gset
SELECT id AS legacy_report_id FROM transfer_reports WHERE dedupe_key = 'candidate-legacy' \\gset
SELECT id AS pending_report_id FROM transfer_reports WHERE dedupe_key = 'candidate-pending' \\gset

INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
VALUES (:source_id, '996000000000000101', 'https://x.com/candfixture/status/101', 'active', CURRENT_TIMESTAMP)
RETURNING id AS active_raw_id \\gset
INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
VALUES (:source_id, '996000000000000102', 'https://x.com/candfixture/status/102', 'legacy', CURRENT_TIMESTAMP)
RETURNING id AS legacy_raw_id \\gset
INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
VALUES (:source_id, '996000000000000103', 'https://x.com/candfixture/status/103', 'pending', CURRENT_TIMESTAMP)
RETURNING id AS pending_raw_id \\gset

INSERT INTO transfer_report_sources (
  transfer_report_id, raw_post_id, source_observed_at, extracted_data, is_preferred
) VALUES
  (:active_report_id, :active_raw_id, CURRENT_TIMESTAMP, '{}'::jsonb, true),
  (:legacy_report_id, :legacy_raw_id, CURRENT_TIMESTAMP, '{}'::jsonb, true),
  (:pending_report_id, :pending_raw_id, CURRENT_TIMESTAMP, '{}'::jsonb, true);

INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot)
VALUES
  (:active_report_id, 1, '${hash('a')}', jsonb_build_object(
    'player_name', 'Candidate Fixture', 'current_club_name', 'Old FC',
    'destination_club_name', 'Active FC', 'classification', 'rumor',
    'move_type', 'permanent', 'confidence', 0.7, 'is_digest_worthy', true,
    'probability_status', 'active_scored', 'probability', jsonb_build_object(
      'engine_version', 'probability-v1', 'normalized_probability', 0.7,
      'current_stage', 'advanced', 'terminal_state', 'open', 'explanation', '{}'::jsonb))),
  (:legacy_report_id, 1, '${hash('b')}', jsonb_build_object(
    'player_name', 'Candidate Fixture', 'current_club_name', 'Old FC',
    'destination_club_name', 'Legacy FC', 'classification', 'rumor',
    'move_type', 'permanent', 'confidence', 0.7, 'is_digest_worthy', true)),
  (:pending_report_id, 1, '${hash('c')}', jsonb_build_object(
    'player_name', 'Candidate Fixture', 'current_club_name', 'Old FC',
    'destination_club_name', 'Pending FC', 'classification', 'rumor',
    'move_type', 'permanent', 'confidence', 0.7, 'is_digest_worthy', true,
    'probability_status', 'active_scored', 'probability', jsonb_build_object(
      'engine_version', 'probability-v1', 'normalized_probability', 0.8,
      'current_stage', 'advanced', 'terminal_state', 'open', 'explanation', '{}'::jsonb)));

PREPARE generated_candidates(timestamptz, timestamptz, text, text) AS
${node.parameters.query};

CREATE TEMP TABLE candidates_off AS
  EXECUTE generated_candidates('2000-01-01', '2100-01-01', 'off', 'off');
CREATE TEMP TABLE candidates_shadow AS
  EXECUTE generated_candidates('2000-01-01', '2100-01-01', 'shadow', 'off');
CREATE TEMP TABLE candidates_active AS
  EXECUTE generated_candidates('2000-01-01', '2100-01-01', 'active', 'off');

SELECT pg_temp.assert_true('off mode selected a fresh active probability revision',
  (SELECT count(*) FROM candidates_off
    WHERE row_type = 'candidate'
      AND payload->'snapshot'->>'destination_club_name' = 'Legacy FC') = 1
  AND NOT EXISTS (SELECT 1 FROM candidates_off
    WHERE row_type = 'candidate'
      AND payload->'snapshot'->>'probability_status' = 'active_scored'));
SELECT pg_temp.assert_true('shadow mode selected a fresh active probability revision',
  (SELECT count(*) FROM candidates_shadow
    WHERE row_type = 'candidate'
      AND payload->'snapshot'->>'destination_club_name' = 'Legacy FC') = 1
  AND NOT EXISTS (SELECT 1 FROM candidates_shadow
    WHERE row_type = 'candidate'
      AND payload->'snapshot'->>'probability_status' = 'active_scored'));
SELECT pg_temp.assert_true('active mode did not select both active and legacy revisions',
  (SELECT count(*) FROM candidates_active
    WHERE row_type = 'candidate'
      AND payload->'snapshot'->>'destination_club_name' IN ('Active FC', 'Legacy FC', 'Pending FC')) = 3
  AND EXISTS (SELECT 1 FROM candidates_active
    WHERE row_type = 'candidate' AND payload->'snapshot'->>'probability_status' = 'active_scored')
  AND EXISTS (SELECT 1 FROM candidates_active
    WHERE row_type = 'candidate' AND payload->'snapshot'->>'probability_status' IS NULL));

INSERT INTO digest_deliveries (
  idempotency_key, channel_key, window_started_at, window_ended_at,
  status, request_payload
) VALUES ('candidate-pending-delivery', 'transfers', CURRENT_TIMESTAMP,
  CURRENT_TIMESTAMP + interval '6 hours', 'pending', '{"frozen":true}'::jsonb)
RETURNING id AS delivery_id \\gset
INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
SELECT :delivery_id, id, 1 FROM transfer_report_revisions
WHERE transfer_report_id = :pending_report_id;

CREATE TEMP TABLE candidates_pending_off AS
  EXECUTE generated_candidates('2000-01-01', '2100-01-01', 'off', 'off');
SELECT pg_temp.assert_true('off mode did not preserve a pending frozen payload',
  (SELECT count(*) FROM candidates_pending_off WHERE row_type = 'candidate') = 1
  AND (SELECT payload->>'pending_idempotency_key' = 'candidate-pending-delivery'
      AND payload->'pending_request_payload' = '{"frozen":true}'::jsonb
    FROM candidates_pending_off WHERE row_type = 'candidate'));

DEALLOCATE generated_candidates;
ROLLBACK;
SELECT 'generated probability candidate tests passed' AS result;
`;

await writeFile(output, sql);
