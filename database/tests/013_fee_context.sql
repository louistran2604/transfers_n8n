\set ON_ERROR_STOP on

BEGIN;

CREATE FUNCTION pg_temp.assert_true(label text, condition boolean)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  IF condition IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END;
$$;

INSERT INTO source_accounts (
  external_account_id, username, display_name, account_type, priority_rank,
  reliability_score, seed_reliability, publisher_group_key, source_kind
) VALUES ('950000000000000001', 'feecontexttest', 'Fee Context Test', 'individual', 2,
  0.850, 0.850, 'reporter:fee-context-test', 'journalist')
RETURNING id AS source_id \gset

CREATE FUNCTION pg_temp.make_fee_report(label text, fee_currency text DEFAULT 'EUR',
  add_ons_currency text DEFAULT 'EUR', base_fee numeric DEFAULT 25000000,
  add_ons numeric DEFAULT 5000000)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; case_id bigint; report_id bigint; raw_post_id bigint;
BEGIN
  INSERT INTO players (identity_key, display_name, normalized_name)
  VALUES ('fee-' || label, 'Fee ' || label, 'fee ' || label) RETURNING id INTO player_id;
  INSERT INTO transfer_cases (case_key, player_id, normalized_current_club, transfer_window_key)
  VALUES ('fee-' || label || '|old-fc|2026-H2', player_id, 'old fc', '2026-H2')
  RETURNING id INTO case_id;
  INSERT INTO raw_posts (source_account_id, platform, external_post_id, post_url, content,
    content_sha256, posted_at, processing_state)
  VALUES ((SELECT id FROM source_accounts WHERE username = 'feecontexttest'),
    'x', nextval('pg_temp.fixture_id')::text,
    'https://x.com/feecontexttest/status/' || currval('pg_temp.fixture_id'), 'fee context',
    encode(sha256(convert_to('fee-' || label, 'UTF8')), 'hex'), '2026-08-27', 'merged')
  RETURNING id INTO raw_post_id;
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
    classification, confidence, fee_amount, fee_currency, add_ons_amount, add_ons_currency,
    first_reported_at, last_reported_at, transfer_case_id, transfer_stage,
    raw_probability, normalized_probability, probability_engine_version,
    probability_explanation, probability_updated_at, probability_status
  ) VALUES ('fee-' || label || '|old-fc|new-fc', player_id, 'Fee ' || label,
    'Old FC', 'New FC', 'rumor', 0.8, base_fee, fee_currency, add_ons,
    add_ons_currency, '2026-08-27', '2026-08-27', case_id, 'advanced', 0.6, 0.6,
    'probability-v1', '{}'::jsonb, '2026-08-27', 'active_scored')
  RETURNING id INTO report_id;
  INSERT INTO transfer_report_sources (transfer_report_id, raw_post_id, source_observed_at, is_preferred)
  VALUES (report_id, raw_post_id, '2026-08-27', true);
  INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot)
  VALUES (report_id, 1, encode(sha256(convert_to('revision-' || label, 'UTF8')), 'hex'),
    jsonb_build_object('player_name', 'Fee ' || label, 'current_club_name', 'Old FC',
      'destination_club_name', 'New FC', 'classification', 'rumor', 'move_type', 'permanent',
      'fee_amount', base_fee, 'fee_currency', fee_currency, 'add_ons_amount', add_ons,
      'add_ons_currency', add_ons_currency, 'confidence', 0.8, 'is_digest_worthy', true,
      'probability_status', 'active_scored', 'probability', jsonb_build_object(
        'engine_version', 'probability-v1', 'normalized_probability', 0.6,
        'current_stage', 'advanced', 'explanation', '{}'::jsonb)));
  INSERT INTO transfer_probability_revisions (
    transfer_report_id, transfer_case_id, revision_number, engine_version, evaluated_at,
    raw_probability, normalized_probability, current_stage, explanation, input_fingerprint
  ) VALUES (report_id, case_id, 1, 'probability-v1', '2026-08-27', 0.6, 0.6,
    'advanced', '{}'::jsonb, encode(sha256(convert_to('probability-' || label, 'UTF8')), 'hex'));
  RETURN report_id;
END;
$$;

CREATE SEQUENCE pg_temp.fixture_id START 950000000000000010;

CREATE FUNCTION pg_temp.attach_profile(report_id bigint, market_currency text,
  market_value numeric, retrieved_at timestamptz, fresh_until timestamptz)
RETURNS bigint LANGUAGE plpgsql AS $$
DECLARE player_id bigint; provider_id bigint; snapshot_id bigint;
BEGIN
  SELECT transfer_reports.player_id INTO player_id FROM transfer_reports WHERE id = report_id;
  INSERT INTO player_provider_ids (player_id, provider_player_id, canonical_name, mapping_source,
    resolver_version, evidence, verified_at, last_seen_at)
  VALUES (player_id, nextval('pg_temp.fixture_id')::text, 'Fee Player', 'automatic',
    'identity-v9', '{}'::jsonb, retrieved_at, retrieved_at) RETURNING id INTO provider_id;
  INSERT INTO transfer_report_player_resolutions (transfer_report_id, player_provider_id,
    resolution_source, resolver_version, evidence, verified_at)
  VALUES (report_id, provider_id, 'automatic', 'identity-v9', '{}'::jsonb, retrieved_at);
  INSERT INTO player_profile_snapshots (player_provider_id, canonical_name, market_value,
    market_value_currency, stable_source_identifier, provider_retrieved_at, fresh_until,
    normalized_schema_version, resolver_version, content_sha256, raw_sha256, raw_cache_key)
  VALUES (provider_id, 'Fee Player', market_value, market_currency, 'sofascore:test', retrieved_at,
    fresh_until, 'profile-v1', 'identity-v9', repeat('a', 64), repeat('b', 64),
    'profile:' || provider_id) RETURNING id INTO snapshot_id;
  RETURN snapshot_id;
END;
$$;

SELECT pg_temp.make_fee_report('fresh') AS fresh_report_id \gset
SELECT pg_temp.attach_profile(:fresh_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS fresh_snapshot_id \gset

SELECT count(*) AS probability_count_before FROM transfer_probability_revisions \gset
SELECT project_transfer_fee_context('2026-08-28 00:00:00+00') AS projected \gset
SELECT pg_temp.assert_true('fresh context was not projected once', :projected = 1);
SELECT pg_temp.assert_true('fresh context fields or ratios are wrong',
  (SELECT snapshot #>> '{fee_context,profile_snapshot_id}' = :'fresh_snapshot_id'
      AND (snapshot #>> '{fee_context,market_value}')::numeric = 20000000
      AND snapshot #>> '{fee_context,market_value_currency}' = 'EUR'
      AND (snapshot #>> '{fee_context,market_value_as_of}')::timestamptz = '2026-08-27 00:00:00+00'
      AND (snapshot #>> '{fee_context,stale}')::boolean = false
      AND (snapshot #>> '{fee_context,guaranteed_fee_ratio}')::numeric = 1.25
      AND (snapshot #>> '{fee_context,fee_plus_add_ons_ratio}')::numeric = 1.5
    FROM transfer_report_revisions WHERE transfer_report_id = :fresh_report_id
    ORDER BY revision_number DESC LIMIT 1));
SELECT pg_temp.assert_true('fee projection changed probability revisions',
  (SELECT count(*) FROM transfer_probability_revisions) = :probability_count_before
  AND (SELECT raw_probability = 0.6 AND normalized_probability = 0.6
      AND current_stage = 'advanced'
      AND input_fingerprint = encode(sha256(convert_to('probability-fresh', 'UTF8')), 'hex')
    FROM transfer_probability_revisions WHERE transfer_report_id = :fresh_report_id)
  AND (SELECT newest.snapshot->'probability' = oldest.snapshot->'probability'
    FROM LATERAL (SELECT snapshot FROM transfer_report_revisions
      WHERE transfer_report_id = :fresh_report_id ORDER BY revision_number LIMIT 1) oldest,
    LATERAL (SELECT snapshot FROM transfer_report_revisions
      WHERE transfer_report_id = :fresh_report_id ORDER BY revision_number DESC LIMIT 1) newest));
SELECT count(*) AS revision_count_after FROM transfer_report_revisions
WHERE transfer_report_id = :fresh_report_id \gset
SELECT pg_temp.assert_true('repeat projection was not idempotent',
  project_transfer_fee_context('2026-08-28 00:00:00+00') = 0
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :fresh_report_id) = :revision_count_after);

SELECT pg_temp.make_fee_report('mismatch', 'GBP', 'GBP') AS mismatch_report_id \gset
SELECT pg_temp.attach_profile(:mismatch_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS mismatch_snapshot_id \gset
SELECT pg_temp.make_fee_report('stale') AS stale_report_id \gset
SELECT pg_temp.attach_profile(:stale_report_id, 'EUR', 20000000,
  '2026-08-20 00:00:00+00', '2026-08-21 00:00:00+00') AS stale_snapshot_id \gset
SELECT pg_temp.make_fee_report('missing') AS missing_report_id \gset
SELECT pg_temp.make_fee_report('zero-value') AS zero_value_report_id \gset
SELECT pg_temp.attach_profile(:zero_value_report_id, 'EUR', 0,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS zero_value_snapshot_id \gset
SELECT pg_temp.make_fee_report('missing-fee', base_fee => NULL) AS missing_fee_report_id \gset
SELECT pg_temp.attach_profile(:missing_fee_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS missing_fee_snapshot_id \gset
SELECT pg_temp.make_fee_report('add-on-mismatch', 'EUR', 'GBP') AS add_on_mismatch_report_id \gset
SELECT pg_temp.attach_profile(:add_on_mismatch_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS add_on_mismatch_snapshot_id \gset
SELECT pg_temp.make_fee_report('freshness-equality') AS freshness_equality_report_id \gset
SELECT pg_temp.attach_profile(:freshness_equality_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-28 00:00:00+00') AS freshness_equality_snapshot_id \gset
SELECT pg_temp.assert_true('fail-open contexts were not projected',
  project_transfer_fee_context('2026-08-28 00:00:00+00') = 6);
SELECT pg_temp.assert_true('currency mismatch retained a ratio',
  (SELECT NOT (snapshot->'fee_context' ? 'guaranteed_fee_ratio')
    FROM transfer_report_revisions WHERE transfer_report_id = :mismatch_report_id
    ORDER BY revision_number DESC LIMIT 1));
SELECT pg_temp.assert_true('stale context retained a ratio or lost its stale flag',
  (SELECT (snapshot #>> '{fee_context,stale}')::boolean
      AND NOT (snapshot->'fee_context' ? 'guaranteed_fee_ratio')
    FROM transfer_report_revisions WHERE transfer_report_id = :stale_report_id
    ORDER BY revision_number DESC LIMIT 1));
SELECT pg_temp.assert_true('missing enrichment created a context revision',
  (SELECT count(*) = 1 FROM transfer_report_revisions WHERE transfer_report_id = :missing_report_id));
SELECT pg_temp.assert_true('zero value or missing fee retained a ratio',
  (SELECT NOT (snapshot->'fee_context' ? 'guaranteed_fee_ratio')
    FROM transfer_report_revisions WHERE transfer_report_id = :zero_value_report_id
    ORDER BY revision_number DESC LIMIT 1)
  AND (SELECT NOT (snapshot->'fee_context' ? 'guaranteed_fee_ratio')
      AND NOT (snapshot->'fee_context' ? 'fee_plus_add_ons_ratio')
    FROM transfer_report_revisions WHERE transfer_report_id = :missing_fee_report_id
    ORDER BY revision_number DESC LIMIT 1));
SELECT pg_temp.assert_true('add-on currency mismatch changed the valid base ratio',
  (SELECT (snapshot #>> '{fee_context,guaranteed_fee_ratio}')::numeric = 1.25
      AND NOT (snapshot->'fee_context' ? 'fee_plus_add_ons_ratio')
    FROM transfer_report_revisions WHERE transfer_report_id = :add_on_mismatch_report_id
    ORDER BY revision_number DESC LIMIT 1));
SELECT pg_temp.assert_true('fresh-until equality was not stale or retained ratios',
  (SELECT (snapshot #>> '{fee_context,stale}')::boolean
      AND NOT (snapshot->'fee_context' ? 'guaranteed_fee_ratio')
    FROM transfer_report_revisions WHERE transfer_report_id = :freshness_equality_report_id
    ORDER BY revision_number DESC LIMIT 1));

SELECT pg_temp.make_fee_report('delivered') AS delivered_report_id \gset
SELECT pg_temp.attach_profile(:delivered_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS delivered_snapshot_id \gset
INSERT INTO digest_deliveries (idempotency_key, channel_key, window_started_at, window_ended_at,
  status, request_payload, sent_at)
VALUES ('fee-delivered', 'transfers', '2026-08-27 00:00:00+00', '2026-08-27 06:00:00+00',
  'sent', '{"frozen":true}'::jsonb, '2026-08-27 00:01:00+00') RETURNING id AS delivery_id \gset
INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
SELECT :delivery_id, id, 1 FROM transfer_report_revisions
WHERE transfer_report_id = :delivered_report_id;
SELECT pg_temp.assert_true('delivered report received a fee-only revision',
  project_transfer_fee_context('2026-08-28 00:00:00+00') = 0
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :delivered_report_id) = 1
  AND (SELECT request_payload = '{"frozen":true}'::jsonb FROM digest_deliveries WHERE id = :delivery_id));

SELECT pg_temp.make_fee_report('pending') AS pending_report_id \gset
SELECT pg_temp.attach_profile(:pending_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS pending_snapshot_id \gset
INSERT INTO digest_deliveries (idempotency_key, channel_key, window_started_at, window_ended_at,
  status, request_payload)
VALUES ('fee-pending', 'transfers', '2026-08-27 06:00:00+00', '2026-08-27 12:00:00+00',
  'pending', '{"pending":"frozen"}'::jsonb) RETURNING id AS pending_delivery_id \gset
INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
SELECT :pending_delivery_id, id, 1 FROM transfer_report_revisions
WHERE transfer_report_id = :pending_report_id;
SELECT pg_temp.assert_true('pending report was enriched or its payload was rebuilt',
  project_transfer_fee_context('2026-08-28 00:00:00+00') = 0
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :pending_report_id) = 1
  AND (SELECT request_payload = '{"pending":"frozen"}'::jsonb
    FROM digest_deliveries WHERE id = :pending_delivery_id));

SELECT pg_temp.make_fee_report('historical') AS historical_report_id \gset
SELECT pg_temp.attach_profile(:historical_report_id, 'EUR', 20000000,
  '2026-08-27 00:00:00+00', '2026-08-29 00:00:00+00') AS historical_snapshot_id \gset
UPDATE transfer_report_revisions SET created_at = '2026-07-01 00:00:00+00'
WHERE transfer_report_id = :historical_report_id;
SELECT pg_temp.assert_true('historical undelivered revision was pulled into the current window',
  project_transfer_fee_context('2026-08-28 00:00:00+00',
    '2026-08-27 00:00:00+00', '2026-08-28 00:00:00+00') = 0
  AND (SELECT count(*) FROM transfer_report_revisions WHERE transfer_report_id = :historical_report_id) = 1);

ROLLBACK;

\echo 'fee context tests passed'
