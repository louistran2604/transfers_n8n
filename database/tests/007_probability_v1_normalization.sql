\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN
    RAISE EXCEPTION '%', label;
  END IF;
END;
$$;

CREATE FUNCTION pg_temp.rejects_conflicting_official(report_id bigint, report_payload jsonb)
RETURNS boolean LANGUAGE plpgsql AS $$
BEGIN
  BEGIN
    PERFORM apply_probability_v1_shadow(report_id, report_payload);
    RETURN false;
  EXCEPTION WHEN check_violation THEN
    RETURN true;
  END;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 920000000000000000;

CREATE FUNCTION pg_temp.make_raw(source_id bigint, posted_at timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE
  post_id bigint;
  external_id text := nextval('pg_temp.fixture_id')::text;
BEGIN
  INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
  VALUES (source_id, external_id, 'https://x.com/test/status/' || external_id,
    'probability-v1 normalization fixture', posted_at)
  RETURNING id INTO post_id;
  RETURN post_id;
END;
$$;

CREATE FUNCTION pg_temp.payload(
  raw_post_id bigint,
  destination text,
  stage_signal text DEFAULT 'advanced',
  completion_claim text DEFAULT 'none'
)
RETURNS jsonb LANGUAGE sql AS $$
  SELECT jsonb_build_object(
    'probability_mode', 'shadow',
    'evaluated_at', '2026-08-27T12:00:00Z',
    'destination_club_name', destination,
    'normalized_data', jsonb_build_object('current_club_key', 'old fc'),
    'sources', jsonb_build_array(jsonb_build_object(
      'raw_post_id', raw_post_id,
      'posted_at', post.posted_at,
      'report_ordinal', 1,
      'extraction_schema_version', 'qwen-evidence-v1',
      'normalized_evidence', jsonb_build_object(
        'stage_signal', stage_signal,
        'claim_stance', 'supports',
        'wording_strength', 'direct',
        'club_agreement_state', CASE WHEN stage_signal = 'official_wording' THEN 'agreed' ELSE 'talks' END,
        'personal_terms_state', CASE WHEN stage_signal = 'official_wording' THEN 'agreed' ELSE 'talks' END,
        'completion_claim', completion_claim,
        'attribution_kind', 'original',
        'named_originator', NULL,
        'extraction_confidence', 0.95
      )
    )))
  FROM raw_posts post WHERE post.id = raw_post_id;
$$;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES
  ('920000000000000101', 'normreporter', 'Normalization Reporter', 'individual', 2,
    0.850, 0.850, 'reporter:norm', 'journalist'),
  ('920000000000000102', 'normofficial', 'Normalization Official', 'organization', 1,
    1.000, 1.000, 'club:norm', 'club_official');
SELECT id AS reporter_id FROM source_accounts WHERE username = 'normreporter' \gset
SELECT id AS official_id FROM source_accounts WHERE username = 'normofficial' \gset

-- A one-destination case preserves the Stage 4 raw score exactly.
INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('norm-single', 'Norm Single', 'norm single') RETURNING id AS single_player_id \gset
INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('norm-single|old-fc|2026-H2', :single_player_id, 'old fc', '2026-H2')
RETURNING id AS single_case_id \gset
INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
  classification, confidence, first_reported_at, last_reported_at, transfer_case_id
) VALUES (
  'norm-single|old-fc|solo-fc', :single_player_id, 'Norm Single', 'Old FC', 'Solo FC',
  'rumor', 0.8, '2026-08-27', '2026-08-27', :single_case_id
) RETURNING id AS single_report_id \gset
SELECT pg_temp.make_raw(:reporter_id, '2026-08-27 10:00:00+00') AS single_raw_id \gset
SELECT apply_probability_v1_shadow(:single_report_id, pg_temp.payload(:single_raw_id, 'Solo FC'));
SELECT pg_temp.assert_true('one destination did not preserve raw probability and exact stay complement',
  (SELECT raw_probability = normalized_probability
      AND normalized_probability + stay_probability = 1.00000
    FROM transfer_reports JOIN transfer_cases ON transfer_cases.id = transfer_case_id
    WHERE transfer_reports.id = :single_report_id));

-- Two destinations share one locked case.
INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('norm-multi', 'Norm Multi', 'norm multi') RETURNING id AS multi_player_id \gset
INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
VALUES ('norm-multi|old-fc|2026-H2', :multi_player_id, 'old fc', '2026-H2')
RETURNING id AS multi_case_id \gset
INSERT INTO transfer_reports (
  dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
  classification, confidence, first_reported_at, last_reported_at, transfer_case_id
) VALUES
  ('norm-multi|old-fc|alpha-fc', :multi_player_id, 'Norm Multi', 'Old FC', 'Alpha FC',
    'rumor', 0.8, '2026-08-27', '2026-08-27', :multi_case_id),
  ('norm-multi|old-fc|beta-fc', :multi_player_id, 'Norm Multi', 'Old FC', 'Beta FC',
    'rumor', 0.8, '2026-08-27', '2026-08-27', :multi_case_id);
SELECT id AS alpha_report_id FROM transfer_reports WHERE dedupe_key = 'norm-multi|old-fc|alpha-fc' \gset
SELECT id AS beta_report_id FROM transfer_reports WHERE dedupe_key = 'norm-multi|old-fc|beta-fc' \gset
SELECT pg_temp.make_raw(:reporter_id, '2026-08-27 09:00:00+00') AS alpha_link_raw_id \gset
SELECT pg_temp.make_raw(:reporter_id, '2026-08-27 09:05:00+00') AS beta_raw_id \gset
SELECT apply_probability_v1_shadow(:alpha_report_id, pg_temp.payload(:alpha_link_raw_id, 'Alpha FC', 'link'));
SELECT apply_probability_v1_shadow(:beta_report_id, pg_temp.payload(:beta_raw_id, 'Beta FC'));

SELECT pg_temp.assert_true('two destinations plus stay do not total exactly 1.00000',
  (SELECT sum(normalized_probability) + max(stay_probability) = 1.00000
   FROM transfer_reports JOIN transfer_cases ON transfer_cases.id = transfer_case_id
   WHERE transfer_case_id = :multi_case_id));
CREATE TEMPORARY TABLE beta_before AS
SELECT raw_probability, normalized_probability,
  (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :beta_report_id) AS revision_count
FROM transfer_reports WHERE id = :beta_report_id;

-- Strengthening Alpha must revise unchanged Beta solely through competition.
SELECT pg_temp.make_raw(:reporter_id, '2026-08-27 11:00:00+00') AS alpha_stronger_raw_id \gset
SELECT apply_probability_v1_shadow(:alpha_report_id, pg_temp.payload(:alpha_stronger_raw_id, 'Alpha FC'));
SELECT pg_temp.assert_true('stronger destination did not lower the unchanged competitor share',
  (SELECT report.raw_probability = before.raw_probability
      AND report.normalized_probability < before.normalized_probability
      AND (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_report_id = :beta_report_id)
        = before.revision_count + 1
    FROM transfer_reports report CROSS JOIN beta_before before WHERE report.id = :beta_report_id));
SELECT pg_temp.assert_true('competition-only revision explanation does not reconcile',
  (SELECT revision.explanation->>'change_classification' = 'competition_only'
      AND revision.explanation->>'normalization' = 'case-level-destination-stay'
      AND revision.explanation ? 'stage'
      AND (revision.explanation->>'raw_probability')::numeric = revision.raw_probability
      AND (revision.explanation->>'normalized_probability')::numeric = revision.normalized_probability
      AND (revision.explanation->>'previous_probability')::numeric = revision.previous_probability
      AND revision.previous_probability = before.normalized_probability
      AND (revision.explanation->>'delta')::numeric = revision.probability_delta
      AND revision.normalized_probability - revision.previous_probability = revision.probability_delta
      AND (revision.explanation->>'competition_adjustment')::numeric
        = revision.normalized_probability - revision.raw_probability
      AND (revision.explanation->>'stay_probability')::numeric
        = (SELECT stay_probability FROM transfer_cases WHERE id = :multi_case_id)
      AND jsonb_array_length(revision.explanation->'normalization_inputs') = 2
      AND (revision.explanation #>> '{normalization_inputs,0,report_id}')::bigint <
        (revision.explanation #>> '{normalization_inputs,1,report_id}')::bigint
      AND revision.explanation = (SELECT probability_explanation FROM transfer_reports WHERE id = :beta_report_id)
    FROM transfer_probability_revisions revision CROSS JOIN beta_before before
    WHERE revision.transfer_report_id = :beta_report_id
    ORDER BY revision.revision_number DESC LIMIT 1));

SELECT version_counter AS replay_version FROM transfer_cases WHERE id = :multi_case_id \gset
SELECT count(*) AS replay_revisions FROM transfer_probability_revisions WHERE transfer_case_id = :multi_case_id \gset
SELECT apply_probability_v1_shadow(:alpha_report_id, pg_temp.payload(:alpha_stronger_raw_id, 'Alpha FC'));
SELECT pg_temp.assert_true('identical replay created revisions or incremented the case version',
  (SELECT version_counter = :replay_version FROM transfer_cases WHERE id = :multi_case_id)
  AND (SELECT count(*) = :replay_revisions FROM transfer_probability_revisions WHERE transfer_case_id = :multi_case_id));

-- Verified official confirmation locks the case outcome.
SELECT pg_temp.make_raw(:official_id, '2026-08-27 11:30:00+00') AS alpha_official_raw_id \gset
SELECT apply_probability_v1_shadow(:alpha_report_id,
  pg_temp.payload(:alpha_official_raw_id, 'Alpha FC', 'official_wording', 'official_announcement'));
SELECT pg_temp.assert_true('official confirmation did not lock destination/competitor/stay shares',
  (SELECT normalized_probability = 1.00000 FROM transfer_reports WHERE id = :alpha_report_id)
  AND (SELECT normalized_probability = 0.00000 FROM transfer_reports WHERE id = :beta_report_id)
  AND (SELECT stay_probability = 0.00000 FROM transfer_cases WHERE id = :multi_case_id));

-- A second official destination is invalid and the entire application rolls back.
CREATE TEMPORARY TABLE official_before AS
SELECT
  (SELECT count(*) FROM transfer_evidence WHERE transfer_case_id = :multi_case_id) AS evidence_count,
  (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_case_id = :multi_case_id) AS revision_count,
  (SELECT version_counter FROM transfer_cases WHERE id = :multi_case_id) AS version_counter;
SELECT pg_temp.make_raw(:official_id, '2026-08-27 11:45:00+00') AS beta_official_raw_id \gset
SELECT pg_temp.assert_true('conflicting official destination was accepted',
  pg_temp.rejects_conflicting_official(:beta_report_id,
    pg_temp.payload(:beta_official_raw_id, 'Beta FC', 'official_wording', 'official_announcement')));
SELECT pg_temp.assert_true('rejected official conflict changed case evidence, revisions, version, or projections',
  (SELECT count(*) FROM transfer_evidence WHERE transfer_case_id = :multi_case_id)
    = (SELECT evidence_count FROM official_before)
  AND (SELECT count(*) FROM transfer_probability_revisions WHERE transfer_case_id = :multi_case_id)
    = (SELECT revision_count FROM official_before)
  AND (SELECT version_counter FROM transfer_cases WHERE id = :multi_case_id)
    = (SELECT version_counter FROM official_before)
  AND (SELECT normalized_probability = 1.00000 FROM transfer_reports WHERE id = :alpha_report_id)
  AND (SELECT normalized_probability = 0.00000 FROM transfer_reports WHERE id = :beta_report_id)
  AND (SELECT stay_probability = 0.00000 FROM transfer_cases WHERE id = :multi_case_id));

DO $$
BEGIN
  IF (SELECT count(*) FROM app_schema_migrations WHERE version = '005_probability_v1_normalization') <> 1 THEN
    RAISE EXCEPTION 'Migration 005_probability_v1_normalization has not been applied exactly once';
  END IF;
END;
$$;

ROLLBACK;

SELECT 'probability-v1 normalization tests passed' AS result;
