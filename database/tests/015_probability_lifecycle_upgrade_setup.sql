\set ON_ERROR_STOP on

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('940000000000000301', 'lifecycleup', 'Lifecycle Upgrade', 'individual', 2,
  0.850, 0.850, 'reporter:lifecycle-upgrade', 'journalist')
RETURNING id AS source_id \gset

CREATE FUNCTION pg_temp.lifecycle_case(label text, requested_status text DEFAULT 'open')
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('lifecycle-upgrade-' || label, 'Lifecycle ' || label, 'lifecycle ' || label)
  RETURNING id INTO player_id;
  INSERT INTO transfer_cases (
    case_key, player_id, normalized_current_club, transfer_window_key, status
  ) VALUES (
    'lifecycle-upgrade-' || label || '|old|2026-H2', player_id, 'old', '2026-H2', requested_status
  ) RETURNING id INTO case_id;
  RETURN case_id;
END;
$$;

SELECT pg_temp.lifecycle_case('official') AS official_case_id \gset
SELECT pg_temp.lifecycle_case('collapsed') AS collapsed_case_id \gset
SELECT pg_temp.lifecycle_case('mixed') AS mixed_case_id \gset
SELECT pg_temp.lifecycle_case('closed', 'closed') AS closed_case_id \gset

INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
  classification, confidence, first_reported_at, last_reported_at, transfer_case_id,
  transfer_stage, probability_status, probability_engine_version, normalized_probability,
  probability_updated_at, probability_explanation
)
SELECT 'lifecycle-upgrade-official', player_id, 'Lifecycle Official', 'Old', 'New',
  'rumor', 0.9, '2026-08-01'::timestamptz, '2026-08-01'::timestamptz, id, 'done', 'shadow_scored',
  'probability-v1', 1.0, '2026-08-06 12:00:00+00'::timestamptz, '{"terminal_kind":"official_confirmation"}'::jsonb
FROM transfer_cases WHERE id = :official_case_id
UNION ALL
SELECT 'lifecycle-upgrade-collapsed', player_id, 'Lifecycle Collapsed', 'Old', 'New',
  'rumor', 0.9, '2026-08-01'::timestamptz, '2026-08-01'::timestamptz, id, 'collapsed', 'shadow_scored',
  'probability-v1', 0.02, '2026-08-06 12:00:00+00'::timestamptz, '{"terminal_kind":"authoritative_collapse"}'::jsonb
FROM transfer_cases WHERE id = :collapsed_case_id
UNION ALL
SELECT 'lifecycle-upgrade-mixed-live', player_id, 'Lifecycle Mixed', 'Old', 'New',
  'rumor', 0.9, '2026-08-01'::timestamptz, '2026-08-01'::timestamptz, id, 'link', 'shadow_scored',
  'probability-v1', 0.40, '2026-08-06 12:00:00+00'::timestamptz, '{}'::jsonb
FROM transfer_cases WHERE id = :mixed_case_id
UNION ALL
SELECT 'lifecycle-upgrade-mixed-collapsed', player_id, 'Lifecycle Mixed', 'Old', 'Other',
  'rumor', 0.9, '2026-08-01'::timestamptz, '2026-08-01'::timestamptz, id, 'collapsed', 'legacy_unscored',
  NULL::text, NULL::numeric, NULL::timestamptz, '{}'::jsonb
FROM transfer_cases WHERE id = :mixed_case_id
UNION ALL
SELECT 'lifecycle-upgrade-closed', player_id, 'Lifecycle Closed', 'Old', 'New',
  'rumor', 0.9, '2026-08-01'::timestamptz, '2026-08-01'::timestamptz, id, 'done', 'shadow_scored',
  'probability-v1', 1.0, '2026-08-06 12:00:00+00'::timestamptz, '{"terminal_kind":"official_confirmation"}'::jsonb
FROM transfer_cases WHERE id = :closed_case_id;

INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
SELECT :source_id, '9400000000000003' || row_number() OVER (ORDER BY report.id),
  'https://x.com/lifecycleup/status/' || report.id, 'lifecycle upgrade fixture',
  '2026-08-01 12:00:00+00'
FROM transfer_reports report WHERE report.dedupe_key LIKE 'lifecycle-upgrade-%'
RETURNING id, external_post_id;

INSERT INTO transfer_evidence (
  transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
  report_ordinal, destination_club_name, stage_signal, claim_stance, wording_strength,
  club_agreement_state, personal_terms_state, completion_claim, attribution_kind,
  resolved_independence_key, extraction_confidence, raw_normalized_extraction
)
SELECT report.id, report.transfer_case_id, post.id, 'qwen-evidence-v1', 1,
  report.destination_club_name, 'link', 'supports', 'direct', 'not_reported',
  'not_reported', 'none', 'original', 'reporter:lifecycle-upgrade', 0.95,
  jsonb_build_object('stage_signal', 'link', 'claim_stance', 'supports',
    'wording_strength', 'direct', 'club_agreement_state', 'not_reported',
    'personal_terms_state', 'not_reported', 'completion_claim', 'none',
    'attribution_kind', 'original', 'named_originator', NULL, 'extraction_confidence', 0.95)
FROM transfer_reports report
JOIN raw_posts post ON post.post_url = 'https://x.com/lifecycleup/status/' || report.id
WHERE report.dedupe_key IN (
  'lifecycle-upgrade-official', 'lifecycle-upgrade-collapsed',
  'lifecycle-upgrade-mixed-live', 'lifecycle-upgrade-closed'
);
