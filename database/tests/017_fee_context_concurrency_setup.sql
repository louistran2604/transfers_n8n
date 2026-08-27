\set ON_ERROR_STOP on

\i /database/tests/018_fee_context_concurrency_cleanup.sql

CREATE TABLE fee_context_concurrency_fixture (
  label text PRIMARY KEY,
  report_id bigint NOT NULL
);

CREATE SEQUENCE fee_context_concurrency_id START 960000000000000001;

DO $$
DECLARE
  label text;
  player_id bigint;
  report_id bigint;
  provider_id bigint;
BEGIN
  FOREACH label IN ARRAY ARRAY['projection', 'material', 'pending'] LOOP
    INSERT INTO players (identity_key, display_name, normalized_name)
    VALUES ('fee-concurrency-' || label, 'Fee Concurrency ' || label,
      'fee concurrency ' || label) RETURNING id INTO player_id;
    INSERT INTO transfer_reports (
      dedupe_key, player_id, reported_player_name, current_club_name,
      destination_club_name, classification, confidence, fee_amount, fee_currency,
      add_ons_amount, add_ons_currency, first_reported_at, last_reported_at
    ) VALUES ('fee-concurrency-' || label, player_id, 'Fee Concurrency ' || label,
      'Old FC', 'New FC', 'rumor', 0.8, 25000000, 'EUR', 5000000, 'EUR',
      '2099-01-01', '2099-01-01') RETURNING id INTO report_id;
    INSERT INTO transfer_report_revisions (
      transfer_report_id, revision_number, content_sha256, snapshot, created_at
    ) VALUES (report_id, 1,
      encode(sha256(convert_to('fee-concurrency-' || label, 'UTF8')), 'hex'),
      jsonb_build_object(
        'player_name', 'Fee Concurrency ' || label,
        'current_club_name', 'Old FC', 'destination_club_name', 'New FC',
        'classification', 'rumor', 'move_type', 'permanent',
        'fee_amount', 25000000, 'fee_currency', 'EUR',
        'add_ons_amount', 5000000, 'add_ons_currency', 'EUR',
        'confidence', 0.8, 'is_digest_worthy', true
      ), '2099-01-01 01:00:00+00');
    INSERT INTO player_provider_ids (
      player_id, provider_player_id, canonical_name, mapping_source,
      resolver_version, evidence, verified_at, last_seen_at
    ) VALUES (player_id, nextval('fee_context_concurrency_id')::text,
      'Fee Concurrency ' || label, 'automatic', 'identity-v9', '{}'::jsonb,
      '2099-01-01', '2099-01-01') RETURNING id INTO provider_id;
    INSERT INTO transfer_report_player_resolutions (
      transfer_report_id, player_provider_id, resolution_source,
      resolver_version, evidence, verified_at
    ) VALUES (report_id, provider_id, 'automatic', 'identity-v9', '{}'::jsonb,
      '2099-01-01');
    INSERT INTO player_profile_snapshots (
      player_provider_id, canonical_name, market_value, market_value_currency,
      stable_source_identifier, provider_retrieved_at, fresh_until,
      normalized_schema_version, resolver_version, content_sha256, raw_sha256,
      raw_cache_key
    ) VALUES (provider_id, 'Fee Concurrency ' || label, 20000000, 'EUR',
      'sofascore:fee-concurrency:' || label, '2099-01-01', '2099-02-01',
      'profile-v1', 'identity-v9',
      encode(sha256(convert_to('profile-' || label, 'UTF8')), 'hex'),
      encode(sha256(convert_to('raw-' || label, 'UTF8')), 'hex'),
      'fee-concurrency:' || label);
    INSERT INTO fee_context_concurrency_fixture VALUES (label, report_id);
  END LOOP;
END;
$$;

CREATE FUNCTION fee_context_concurrency_mutate()
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  pending_delivery_id bigint;
BEGIN
  PERFORM report.id
  FROM transfer_reports report
  JOIN fee_context_concurrency_fixture fixture ON fixture.report_id = report.id
  ORDER BY report.id
  FOR UPDATE OF report;

  PERFORM pg_advisory_xact_lock(960008);

  INSERT INTO transfer_report_revisions (
    transfer_report_id, revision_number, content_sha256, snapshot, created_at
  )
  SELECT fixture.report_id, 2,
    encode(sha256(convert_to('fee-concurrency-new-material', 'UTF8')), 'hex'),
    revision.snapshot || jsonb_build_object('classification', 'confirmed'),
    '2099-01-01 02:00:00+00'
  FROM fee_context_concurrency_fixture fixture
  JOIN transfer_report_revisions revision
    ON revision.transfer_report_id = fixture.report_id AND revision.revision_number = 1
  WHERE fixture.label = 'material';

  INSERT INTO digest_deliveries (
    idempotency_key, channel_key, window_started_at, window_ended_at,
    status, request_payload
  ) VALUES ('fee-concurrency-pending', 'transfers', '2099-01-01 00:00:00+00',
    '2099-01-01 06:00:00+00', 'pending', '{"frozen":"exact"}'::jsonb)
  RETURNING id INTO pending_delivery_id;
  INSERT INTO digest_items (
    digest_delivery_id, transfer_report_revision_id, position
  )
  SELECT pending_delivery_id, revision.id, 1
  FROM fee_context_concurrency_fixture fixture
  JOIN transfer_report_revisions revision
    ON revision.transfer_report_id = fixture.report_id AND revision.revision_number = 1
  WHERE fixture.label = 'pending';
END;
$$;
