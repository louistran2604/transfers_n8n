\set ON_ERROR_STOP on

DROP TRIGGER IF EXISTS probability_v1_concurrency_pause ON transfer_evidence;
DROP FUNCTION IF EXISTS probability_v1_concurrency_pause();
DROP TABLE IF EXISTS probability_v1_concurrency_fixture;

CREATE TABLE probability_v1_concurrency_fixture (
  label text PRIMARY KEY,
  report_id bigint NOT NULL,
  payload jsonb NOT NULL
);

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('930000000000000101', 'concurrencytest', 'Concurrency Test', 'individual', 2,
  0.850, 0.850, 'reporter:concurrency', 'journalist')
RETURNING id AS source_id \gset

INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('probability-v1-concurrency', 'Concurrency Player', 'concurrency player')
RETURNING id AS player_id \gset

INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('probability-v1-concurrency|old-fc|2026-H2', :player_id, 'old fc', '2026-H2')
RETURNING id AS case_id \gset

INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
  classification, confidence, first_reported_at, last_reported_at, transfer_case_id
) VALUES
  ('probability-v1-concurrency|alpha', :player_id, 'Concurrency Player', 'Old FC', 'Alpha FC',
    'rumor', 0.8, '2026-08-27', '2026-08-27', :case_id),
  ('probability-v1-concurrency|beta', :player_id, 'Concurrency Player', 'Old FC', 'Beta FC',
    'rumor', 0.8, '2026-08-27', '2026-08-27', :case_id);
SELECT id AS alpha_report_id FROM transfer_reports
WHERE dedupe_key = 'probability-v1-concurrency|alpha' \gset
SELECT id AS beta_report_id FROM transfer_reports
WHERE dedupe_key = 'probability-v1-concurrency|beta' \gset

INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
VALUES
  (:source_id, '930000000000000201', 'https://x.com/test/status/930000000000000201', 'Alpha initial', '2026-08-27 09:00:00+00'),
  (:source_id, '930000000000000202', 'https://x.com/test/status/930000000000000202', 'Beta initial', '2026-08-27 09:01:00+00'),
  (:source_id, '930000000000000203', 'https://x.com/test/status/930000000000000203', 'Alpha concurrent', '2026-08-27 10:00:00+00'),
  (:source_id, '930000000000000204', 'https://x.com/test/status/930000000000000204', 'Beta concurrent', '2026-08-27 10:01:00+00');

CREATE FUNCTION pg_temp.concurrent_payload(raw_id bigint, destination text, evaluated_at text)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'probability_mode', 'shadow',
    'evaluated_at', evaluated_at,
    'destination_club_name', destination,
    'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
    'sources', jsonb_build_array(jsonb_build_object(
      'raw_post_id', post.id,
      'posted_at', post.posted_at,
      'report_ordinal', 1,
      'extraction_schema_version', 'qwen-evidence-v1',
      'normalized_evidence', jsonb_build_object(
        'stage_signal', 'advanced',
        'claim_stance', 'supports',
        'wording_strength', 'direct',
        'club_agreement_state', 'talks',
        'personal_terms_state', 'talks',
        'completion_claim', 'none',
        'attribution_kind', 'original',
        'named_originator', NULL,
        'extraction_confidence', 0.95
      )
    )))
  FROM raw_posts post WHERE post.id = raw_id;
$$;

SELECT id AS alpha_initial_raw_id FROM raw_posts WHERE external_post_id = '930000000000000201' \gset
SELECT id AS beta_initial_raw_id FROM raw_posts WHERE external_post_id = '930000000000000202' \gset
SELECT apply_probability_v1_shadow(:alpha_report_id,
  pg_temp.concurrent_payload(:alpha_initial_raw_id, 'Alpha FC', '2026-08-27T11:00:00Z'));
SELECT apply_probability_v1_shadow(:beta_report_id,
  pg_temp.concurrent_payload(:beta_initial_raw_id, 'Beta FC', '2026-08-27T11:00:00Z'));

SELECT id AS alpha_concurrent_raw_id FROM raw_posts WHERE external_post_id = '930000000000000203' \gset
SELECT id AS beta_concurrent_raw_id FROM raw_posts WHERE external_post_id = '930000000000000204' \gset
INSERT INTO probability_v1_concurrency_fixture (label, report_id, payload) VALUES
  ('alpha', :alpha_report_id,
    pg_temp.concurrent_payload(:alpha_concurrent_raw_id, 'Alpha FC', '2026-08-27T12:00:00Z')),
  ('beta', :beta_report_id,
    pg_temp.concurrent_payload(:beta_concurrent_raw_id, 'Beta FC', '2026-08-27T12:00:00Z'));

CREATE FUNCTION probability_v1_concurrency_pause()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.raw_post_id = (
    SELECT (payload #>> '{sources,0,raw_post_id}')::bigint
    FROM probability_v1_concurrency_fixture WHERE label = 'alpha'
  ) THEN
    PERFORM pg_advisory_xact_lock(930005);
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER probability_v1_concurrency_pause
BEFORE INSERT ON transfer_evidence
FOR EACH ROW EXECUTE FUNCTION probability_v1_concurrency_pause();
