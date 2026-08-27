\set ON_ERROR_STOP on

\i /database/tests/027_probability_same_time_cleanup.sql

CREATE TABLE probability_same_time_fixture (
  label text PRIMARY KEY,
  transfer_case_id bigint NOT NULL
);

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES
  ('995000000000000001', 'sametimerep', 'Same Time Reporter', 'individual', 1,
    0.75, 0.75, 'reporter:same-time', 'journalist'),
  ('995000000000000002', 'sametimefc', 'Same Time FC', 'organization', 1,
    0.90, 0.90, 'official:same-time', 'club_official');

DO $$
DECLARE fixture_number integer; reporter_id bigint; official_id bigint;
  player_id bigint; case_id bigint; report_id bigint; reporter_post bigint; official_post bigint;
BEGIN
  SELECT id INTO reporter_id FROM source_accounts WHERE username = 'sametimerep';
  SELECT id INTO official_id FROM source_accounts WHERE username = 'sametimefc';
  FOR fixture_number IN 1..2 LOOP
    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES ('same-time-' || fixture_number, 'Same Time', 'same time') RETURNING id INTO player_id;
    INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
    VALUES ('same-time-' || fixture_number || '|old|2026-H2', player_id, 'old', '2026-H2')
    RETURNING id INTO case_id;
    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name,
      destination_club_name, classification, confidence, first_reported_at,
      last_reported_at, transfer_case_id
    ) VALUES ('same-time-' || fixture_number, player_id, 'Same Time', 'Old', 'New',
      'rumor', 0.8, '2026-04-01', '2026-04-01', case_id) RETURNING id INTO report_id;
    INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
    VALUES (reporter_id, '99500000000000001' || fixture_number,
      'https://x.com/sametimerep/status/' || fixture_number, 'advanced', '2026-04-01')
    RETURNING id INTO reporter_post;
    INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
    VALUES (official_id, '99500000000000002' || fixture_number,
      'https://x.com/sametimefc/status/' || fixture_number, 'official', '2026-04-02')
    RETURNING id INTO official_post;
    INSERT INTO transfer_evidence (
      transfer_report_id, transfer_case_id, raw_post_id, extraction_schema_version,
      report_ordinal, destination_club_name, stage_signal, claim_stance, wording_strength,
      club_agreement_state, personal_terms_state, completion_claim, attribution_kind,
      resolved_independence_key, extraction_confidence, raw_normalized_extraction
    ) VALUES
      (report_id, case_id, reporter_post, 'qwen-evidence-v1', 1, 'New', 'advanced',
        'supports', 'direct', 'talks', 'talks', 'none', 'original',
        'reporter:same-time', 0.95, jsonb_build_object('_resolved_source', jsonb_build_object(
          'account_id', reporter_id, 'username', 'sametimerep', 'source_kind', 'journalist',
          'seed_reliability', 0.75))),
      (report_id, case_id, official_post, 'qwen-evidence-v1', 1, 'New', 'official_wording',
        'supports', 'definitive', 'agreed', 'agreed', 'official_announcement', 'original',
        'official:same-time', 0.95, jsonb_build_object('_resolved_source', jsonb_build_object(
          'account_id', official_id, 'username', 'sametimefc', 'source_kind', 'club_official',
          'seed_reliability', 0.90)));
    PERFORM probability_v1_register_claims(case_id, '2026-04-01 12:00+00');
    INSERT INTO probability_same_time_fixture VALUES (fixture_number::text, case_id);
  END LOOP;
END;
$$;

CREATE FUNCTION probability_same_time_pause()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.settlement_outcome IS NULL AND NEW.settlement_outcome IS NOT NULL THEN
    PERFORM pg_advisory_lock(950009);
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER probability_same_time_pause
AFTER UPDATE OF settlement_outcome ON source_claim_outcomes
FOR EACH ROW EXECUTE FUNCTION probability_same_time_pause();
