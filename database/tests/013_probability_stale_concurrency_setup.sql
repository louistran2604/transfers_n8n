\set ON_ERROR_STOP on

\i /database/tests/014_probability_stale_concurrency_cleanup.sql

CREATE TABLE probability_stale_concurrency_audit (
  transfer_case_id bigint NOT NULL,
  backend_pid integer NOT NULL
);

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('940000000000000101', 'staleconcur', 'Stale Concurrency', 'individual', 2,
  0.850, 0.850, 'reporter:stale-concurrency', 'journalist')
RETURNING id AS source_id \gset

DO $$
DECLARE
  i integer;
  fixture_source_id bigint;
  player_id bigint;
  case_id bigint;
  report_id bigint;
  raw_id bigint;
BEGIN
  SELECT id INTO fixture_source_id FROM source_accounts
  WHERE external_account_id = '940000000000000101';

  FOR i IN 1..10 LOOP
    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES ('stale-concurrency-' || i, 'Stale Concurrency ' || i, 'stale concurrency ' || i)
    RETURNING id INTO player_id;
    INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
    VALUES ('stale-concurrency-' || i || '|old|2026-H2', player_id, 'old', '2026-H2')
    RETURNING id INTO case_id;
    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
      classification, confidence, first_reported_at, last_reported_at, transfer_case_id,
      probability_status, probability_engine_version, normalized_probability,
      probability_updated_at, probability_explanation
    ) VALUES ('stale-concurrency-' || i, player_id, 'Stale Concurrency ' || i, 'Old', 'New',
      'rumor', 0.8, '2026-08-01', '2026-08-01', case_id, 'shadow_scored', 'probability-v1',
      0.10, '2026-08-06 12:00:00+00', '{}'::jsonb)
    RETURNING id INTO report_id;
    INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
    VALUES (fixture_source_id, '9400000000000002' || lpad(i::text, 2, '0'),
      'https://x.com/staleconcurrency/status/' || i, 'stale concurrency fixture',
      '2026-08-01 12:00:00+00') RETURNING id INTO raw_id;
    INSERT INTO transfer_evidence (
      transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
      report_ordinal, destination_club_name, stage_signal, claim_stance, wording_strength,
      club_agreement_state, personal_terms_state, completion_claim, attribution_kind,
      resolved_independence_key, extraction_confidence, raw_normalized_extraction
    ) VALUES (report_id, case_id, raw_id, 'qwen-evidence-v1', 1, 'New', 'link', 'supports',
      'direct', 'not_reported', 'not_reported', 'none', 'original', 'reporter:stale-concurrency', 0.95,
      jsonb_build_object('stage_signal', 'link', 'claim_stance', 'supports',
        'wording_strength', 'direct', 'club_agreement_state', 'not_reported',
        'personal_terms_state', 'not_reported', 'completion_claim', 'none',
        'attribution_kind', 'original', 'named_originator', NULL, 'extraction_confidence', 0.95));
  END LOOP;
END;
$$;

CREATE FUNCTION probability_stale_concurrency_pause()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.transfer_case_id IN (
    SELECT id FROM transfer_cases WHERE case_key LIKE 'stale-concurrency-%|old|2026-H2'
  ) THEN
    PERFORM pg_advisory_xact_lock(940007);
  END IF;
  RETURN NEW;
END;
$$;

CREATE FUNCTION probability_stale_concurrency_record()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.transfer_case_id IN (
    SELECT id FROM transfer_cases WHERE case_key LIKE 'stale-concurrency-%|old|2026-H2'
  ) THEN
    INSERT INTO probability_stale_concurrency_audit VALUES (NEW.transfer_case_id, pg_backend_pid());
  END IF;
  RETURN NEW;
END;
$$;

CREATE TRIGGER probability_stale_concurrency_pause
BEFORE INSERT ON transfer_probability_revisions
FOR EACH ROW EXECUTE FUNCTION probability_stale_concurrency_pause();
CREATE TRIGGER probability_stale_concurrency_record
AFTER INSERT ON transfer_probability_revisions
FOR EACH ROW EXECUTE FUNCTION probability_stale_concurrency_record();
