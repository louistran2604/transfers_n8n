#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadEntityAliases, loadSourceRegistry } from './lib.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const outputPath = resolve(here, 'football-transfer-monitor.json');
const errorOutputPath = resolve(here, 'football-transfer-monitor-errors.json');
const womensBlacklistPath = resolve(here, 'womens-football-blacklist.txt');
const entityAliasesPath = resolve(here, 'entity-aliases.json');

let entityAliases;

const postgresCredential = { postgres: { id: '', name: 'Transfers PostgreSQL' } };

function node(name, type, position, parameters = {}, extras = {}) {
  return {
    id: name.toLowerCase().replace(/[^a-z0-9]+/g, '-'),
    name,
    type,
    typeVersion: extras.typeVersion ?? 2,
    position,
    parameters,
    ...('credentials' in extras ? { credentials: extras.credentials } : {}),
    ...('continueOnFail' in extras ? { continueOnFail: extras.continueOnFail } : {}),
    ...('retryOnFail' in extras ? { retryOnFail: extras.retryOnFail } : {}),
    ...('maxTries' in extras ? { maxTries: extras.maxTries } : {}),
    ...('waitBetweenTries' in extras ? { waitBetweenTries: extras.waitBetweenTries } : {}),
    ...('onError' in extras ? { onError: extras.onError } : {}),
  };
}

function codeNode(name, position, js) {
  return node(name, 'n8n-nodes-base.code', position, {
    mode: 'runOnceForAllItems',
    jsCode: js.trim(),
  });
}

function postgresNode(name, position, query, queryReplacement, extras = {}) {
  const options = {
    queryBatching: 'transaction',
    outputLargeFormatNumbers: 'text',
  };
  if (/\$\d+\b/.test(query)) options.queryReplacement = queryReplacement ?? '={{ $json.params }}';
  return node(name, 'n8n-nodes-base.postgres', position, {
    operation: 'executeQuery',
    query,
    options,
  }, { credentials: postgresCredential, ...extras });
}

function httpNode(name, position, parameters, extras = {}) {
  const { requestOptions = {}, ...nodeExtras } = extras;
  return node(name, 'n8n-nodes-base.httpRequest', position, {
    ...parameters,
    options: {
      ...requestOptions,
      response: { response: { fullResponse: true, neverError: true } },
    },
  }, { typeVersion: 4.2, ...nodeExtras });
}

function sourceUpsertSql() {
  return `
INSERT INTO source_accounts (
  platform, external_account_id, username, display_name, account_type,
  is_official, priority_rank, reliability_score
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
ON CONFLICT (platform, external_account_id) DO UPDATE
SET username = EXCLUDED.username,
    display_name = EXCLUDED.display_name,
    account_type = EXCLUDED.account_type,
    is_official = EXCLUDED.is_official,
    priority_rank = EXCLUDED.priority_rank,
    reliability_score = EXCLUDED.reliability_score,
    is_active = true
RETURNING id::text AS source_account_id, platform, external_account_id, username,
  display_name, account_type, is_official, priority_rank, reliability_score;`.trim();
}

function rawPostUpsertSql() {
  return `
WITH source AS (
  SELECT id FROM source_accounts WHERE platform = 'x' AND external_account_id = $1
), raw AS (
  INSERT INTO raw_posts (
    source_account_id, platform, external_post_id, post_url, content, posted_at, raw_payload
  ) VALUES ((SELECT id FROM source), 'x', $2, $3, $4, $5::timestamptz, $6::jsonb)
  ON CONFLICT (platform, external_post_id) DO UPDATE
  SET collected_at = CURRENT_TIMESTAMP, raw_payload = EXCLUDED.raw_payload
  RETURNING id
)
SELECT raw.id::text AS raw_post_id, $1::text AS external_account_id, $2::text AS external_post_id,
  $3::text AS post_url, $4::text AS content, $5::text AS posted_at,
  $7::text AS username, $8::text AS display_name, $9::smallint AS priority_rank,
  $10::numeric AS reliability_score, $11::boolean AS is_official
FROM raw;`.trim();
}

function qwenFailureSql() {
  return `
WITH raw AS (
  UPDATE raw_posts SET processing_state = 'failed'
  WHERE id = $1::bigint
  RETURNING id
), failure AS (
  INSERT INTO failures (operation_name, error_fingerprint, error_class, error_message, details)
  VALUES ('qwen_extract', $2, 'ValidationError', $3, $4::jsonb)
  ON CONFLICT (workflow_run_id, operation_name, error_fingerprint) DO UPDATE
  SET occurrences = failures.occurrences + 1, last_seen_at = CURRENT_TIMESTAMP,
      error_message = EXCLUDED.error_message, details = EXCLUDED.details
  RETURNING id
)
INSERT INTO retry_states (resource_type, resource_key, operation_name, state, attempt_count, next_attempt_at, last_failure_id)
VALUES ('raw_post', $5, 'qwen_extract', 'retrying', 1, CURRENT_TIMESTAMP + ($6::integer * interval '1 millisecond'), (SELECT id FROM failure))
ON CONFLICT (resource_type, resource_key, operation_name) DO UPDATE
SET state = CASE WHEN retry_states.attempt_count + 1 >= 3 THEN 'dead_letter' ELSE 'retrying' END,
    attempt_count = retry_states.attempt_count + 1,
    next_attempt_at = CASE WHEN retry_states.attempt_count + 1 >= 3 THEN NULL ELSE EXCLUDED.next_attempt_at END,
    last_failure_id = EXCLUDED.last_failure_id
RETURNING id::text AS retry_state_id, state, attempt_count;`.trim();
}

function mergeReportSql() {
  return `
WITH input AS (SELECT $1::jsonb AS payload),
player AS (
  INSERT INTO players (identity_key, display_name, normalized_name)
  SELECT payload->>'player_identity_key', payload->>'player_name', payload->>'normalized_player_name' FROM input
  ON CONFLICT (identity_key) DO UPDATE SET display_name = EXCLUDED.display_name
  RETURNING id
),
report AS (
  INSERT INTO transfer_reports (
    dedupe_key, player_id, reported_player_name, current_club_name, destination_club_name,
    classification, move_type, fee_amount, fee_currency, add_ons_amount, add_ons_currency,
    release_clause_amount, release_clause_currency, contract_length_months, contract_expires_on,
    loan_ends_on, has_option_to_buy, has_obligation_to_buy, sell_on_percentage, medical_status,
    agreement_status, confidence, first_reported_at, last_reported_at, normalized_data
  )
  SELECT payload->>'dedupe_key', (SELECT id FROM player), payload->>'player_name',
    NULLIF(payload->>'current_club_name', ''), NULLIF(payload->>'destination_club_name', ''),
    payload->>'classification', payload->>'move_type',
    NULLIF(payload->>'fee_amount', '')::numeric, NULLIF(payload->>'fee_currency', ''),
    NULLIF(payload->>'add_ons_amount', '')::numeric, NULLIF(payload->>'add_ons_currency', ''),
    NULLIF(payload->>'release_clause_amount', '')::numeric, NULLIF(payload->>'release_clause_currency', ''),
    NULLIF(payload->>'contract_length_months', '')::integer, NULLIF(payload->>'contract_expires_on', '')::date,
    NULLIF(payload->>'loan_ends_on', '')::date, NULLIF(payload->>'has_option_to_buy', '')::boolean,
    NULLIF(payload->>'has_obligation_to_buy', '')::boolean, NULLIF(payload->>'sell_on_percentage', '')::numeric,
    payload->>'medical_status', payload->>'agreement_status', (payload->>'confidence')::numeric,
    (payload->>'first_reported_at')::timestamptz, (payload->>'last_reported_at')::timestamptz,
    COALESCE(payload->'normalized_data', '{}'::jsonb)
  FROM input
  ON CONFLICT (dedupe_key) DO UPDATE
  SET player_id = CASE
        WHEN EXISTS (
          SELECT 1 FROM transfer_report_player_resolutions
          WHERE transfer_report_id = transfer_reports.id
        ) THEN transfer_reports.player_id
        ELSE EXCLUDED.player_id
      END,
      reported_player_name = EXCLUDED.reported_player_name,
      current_club_name = COALESCE(EXCLUDED.current_club_name, transfer_reports.current_club_name),
      destination_club_name = COALESCE(EXCLUDED.destination_club_name, transfer_reports.destination_club_name),
      classification = EXCLUDED.classification, move_type = EXCLUDED.move_type,
      fee_amount = COALESCE(EXCLUDED.fee_amount, transfer_reports.fee_amount),
      fee_currency = COALESCE(EXCLUDED.fee_currency, transfer_reports.fee_currency),
      add_ons_amount = COALESCE(EXCLUDED.add_ons_amount, transfer_reports.add_ons_amount),
      add_ons_currency = COALESCE(EXCLUDED.add_ons_currency, transfer_reports.add_ons_currency),
      release_clause_amount = COALESCE(EXCLUDED.release_clause_amount, transfer_reports.release_clause_amount),
      release_clause_currency = COALESCE(EXCLUDED.release_clause_currency, transfer_reports.release_clause_currency),
      contract_length_months = COALESCE(EXCLUDED.contract_length_months, transfer_reports.contract_length_months),
      contract_expires_on = COALESCE(EXCLUDED.contract_expires_on, transfer_reports.contract_expires_on),
      loan_ends_on = COALESCE(EXCLUDED.loan_ends_on, transfer_reports.loan_ends_on),
      has_option_to_buy = COALESCE(EXCLUDED.has_option_to_buy, transfer_reports.has_option_to_buy),
      has_obligation_to_buy = COALESCE(EXCLUDED.has_obligation_to_buy, transfer_reports.has_obligation_to_buy),
      sell_on_percentage = COALESCE(EXCLUDED.sell_on_percentage, transfer_reports.sell_on_percentage),
      medical_status = EXCLUDED.medical_status, agreement_status = EXCLUDED.agreement_status,
      confidence = GREATEST(transfer_reports.confidence, EXCLUDED.confidence),
      first_reported_at = LEAST(transfer_reports.first_reported_at, EXCLUDED.first_reported_at),
      last_reported_at = GREATEST(transfer_reports.last_reported_at, EXCLUDED.last_reported_at),
      normalized_data = EXCLUDED.normalized_data
  RETURNING id
),
sources AS (
  INSERT INTO transfer_report_sources (transfer_report_id, raw_post_id, source_observed_at, extracted_data, is_preferred)
  SELECT (SELECT id FROM report), (source->>'raw_post_id')::bigint,
    (source->>'posted_at')::timestamptz, source, false
  FROM input, jsonb_array_elements(input.payload->'sources') AS source
  ON CONFLICT (transfer_report_id, raw_post_id) DO UPDATE
  SET source_observed_at = EXCLUDED.source_observed_at,
      extracted_data = EXCLUDED.extracted_data,
      is_preferred = false
),
mark_merged AS (
  UPDATE raw_posts SET processing_state = 'merged', classified_at = CURRENT_TIMESTAMP
  WHERE id IN (
    SELECT (source->>'raw_post_id')::bigint
    FROM input, jsonb_array_elements(input.payload->'sources') AS source
  )
),
revision AS (
  INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot)
  SELECT (SELECT id FROM report),
    COALESCE((SELECT max(revision_number) + 1 FROM transfer_report_revisions WHERE transfer_report_id = (SELECT id FROM report)), 1),
    payload->>'content_sha256', payload->'snapshot'
  FROM input
  WHERE NOT EXISTS (
    SELECT 1 FROM transfer_report_revisions
    WHERE transfer_report_id = (SELECT id FROM report) AND content_sha256 = input.payload->>'content_sha256'
  )
  ON CONFLICT (transfer_report_id, content_sha256) DO NOTHING
  RETURNING id
)
SELECT (SELECT id::text FROM report) AS transfer_report_id,
  (SELECT id::text FROM revision) AS revision_id,
  (SELECT payload->>'preferred_raw_post_id' FROM input) AS preferred_raw_post_id;`.trim();
}

function enrichmentContextSql() {
  return `
WITH requested_input AS (
  SELECT DISTINCT value::text::bigint AS transfer_report_id
  FROM jsonb_array_elements_text($1::jsonb)
),
historical_candidates AS (
  SELECT tr.id AS transfer_report_id
  FROM transfer_reports tr
  JOIN LATERAL (
    SELECT attempt.status, attempt.retryable, attempt.next_retry_at, attempt.started_at,
      attempt.evidence->>'resolver_version' AS resolver_version
    FROM player_enrichment_attempts attempt
    WHERE attempt.transfer_report_id = tr.id
    ORDER BY attempt.started_at DESC, attempt.id DESC
    LIMIT 1
  ) latest_attempt ON true
  WHERE NOT EXISTS (SELECT 1 FROM requested_input WHERE requested_input.transfer_report_id = tr.id)
    AND NOT EXISTS (
    SELECT 1 FROM transfer_report_player_resolutions resolution
    WHERE resolution.transfer_report_id = tr.id
  )
    AND (
      (
        latest_attempt.status IN ('unresolved', 'ambiguous')
        AND (
          latest_attempt.started_at <= CURRENT_TIMESTAMP - interval '24 hours'
          OR latest_attempt.resolver_version IS DISTINCT FROM 'identity-v7'
        )
      )
      OR (
        latest_attempt.status IN ('provider_failure', 'timeout', 'rate_limited', 'deferred', 'schema_failure')
        AND latest_attempt.retryable
        AND (
          latest_attempt.next_retry_at <= CURRENT_TIMESTAMP
          OR latest_attempt.resolver_version IS DISTINCT FROM 'identity-v7'
        )
      )
    )
  ORDER BY
    (latest_attempt.resolver_version IS DISTINCT FROM 'identity-v7') DESC,
    latest_attempt.started_at,
    tr.id
  LIMIT 25
),
requested AS (
  SELECT transfer_report_id, true AS is_current_request FROM requested_input
  UNION ALL
  SELECT transfer_report_id, false AS is_current_request FROM historical_candidates
)
SELECT
  tr.id::text AS transfer_report_id,
  requested.is_current_request,
  tr.player_id::text AS placeholder_player_id,
  tr.reported_player_name,
  tr.current_club_name,
  tr.normalized_data->>'former_club_name' AS former_club_name,
  tr.destination_club_name,
  tr.classification,
  tr.move_type,
  tr.fee_amount,
  tr.fee_currency,
  tr.confidence,
  COALESCE((latest_revision.snapshot->>'is_huge_rumor')::boolean, false) AS is_huge_rumor,
  COALESCE((latest_revision.snapshot->>'is_digest_worthy')::boolean, false) AS is_digest_worthy,
  source.username AS source_username,
  source.display_name AS source_name,
  source.priority_rank AS source_priority_rank,
  source.reliability_score AS source_reliability_score,
  provider_id.provider_player_id,
  current.profile_snapshot_id::text,
  current.current_provider_team_id::text AS profile_current_provider_team_id,
  current.profile_fresh_until,
  current.statistics_snapshot_id::text,
  current.statistics_fresh_until,
  COALESCE(aliases.rows, '[]'::jsonb) AS aliases,
  COALESCE(overrides.rows, '[]'::jsonb) AS identity_overrides,
  CASE WHEN current.provider_team_id IS NOT NULL
         AND team_mapping.fresh_until > CURRENT_TIMESTAMP
       THEN jsonb_build_object(
         'provider_team_id', current.provider_team_id,
         'provider_unique_tournament_id', competition.provider_unique_tournament_id
       )
       ELSE NULL
  END AS team_mapping,
  team_mapping.fresh_until > CURRENT_TIMESTAMP AS team_mapping_fresh,
  CASE WHEN season.id IS NOT NULL AND season.fresh_until > CURRENT_TIMESTAMP
       THEN jsonb_build_object(
         'provider_season_id', season.provider_season_id,
         'label', season.label,
         'state', season.season_state
       )
       ELSE NULL
  END AS season_mapping,
  season.fresh_until > CURRENT_TIMESTAMP AS season_mapping_fresh,
  latest_attempt.status AS latest_attempt_status,
  latest_attempt.started_at AS latest_attempt_started_at,
  latest_attempt.next_retry_at AS latest_attempt_next_retry_at,
  latest_attempt.resolver_version AS latest_attempt_resolver_version,
  latest_attempt.resolver_version IS DISTINCT FROM 'identity-v7' AS force_resolver_retry,
  $2::text AS workflow_run_id
FROM requested
JOIN transfer_reports tr ON tr.id = requested.transfer_report_id
JOIN LATERAL (
  SELECT
    COALESCE(
      tr.normalized_data->>'reported_name_key',
      NULLIF(btrim(regexp_replace(lower(normalize(tr.reported_player_name, NFKC)), '[[:punct:][:space:]]+', ' ', 'g')), '')
    ) AS reported_name_key,
    COALESCE(
      tr.normalized_data->>'current_club_key',
      NULLIF(btrim(regexp_replace(lower(normalize(tr.current_club_name, NFKC)), '[[:punct:][:space:]]+', ' ', 'g')), '')
    ) AS current_club_key,
    COALESCE(
      tr.normalized_data->>'destination_club_key',
      NULLIF(btrim(regexp_replace(lower(normalize(tr.destination_club_name, NFKC)), '[[:punct:][:space:]]+', ' ', 'g')), '')
    ) AS destination_club_key
) context_key ON true
JOIN LATERAL (
  SELECT revision.snapshot
  FROM transfer_report_revisions revision
  WHERE revision.transfer_report_id = tr.id
  ORDER BY revision.revision_number DESC, revision.id DESC
  LIMIT 1
) latest_revision ON true
LEFT JOIN transfer_report_sources preferred_source
  ON preferred_source.transfer_report_id = tr.id
 AND preferred_source.is_preferred
LEFT JOIN raw_posts post ON post.id = preferred_source.raw_post_id
LEFT JOIN source_accounts source ON source.id = post.source_account_id
LEFT JOIN LATERAL (
  SELECT selected.provider_player_id, selected.player_id
  FROM (
    SELECT provider.provider_player_id, provider.player_id, 0 AS priority
    FROM transfer_report_player_resolutions resolution
    JOIN player_provider_ids provider ON provider.id = resolution.player_provider_id
    WHERE resolution.transfer_report_id = tr.id
    UNION ALL
    SELECT min(provider.provider_player_id), min(provider.player_id), 1 AS priority
    FROM player_aliases alias
    JOIN player_provider_ids provider
      ON provider.player_id = alias.player_id AND provider.provider = 'sofascore'
    WHERE alias.provider = 'sofascore'
      AND alias.is_active
      AND alias.unicode_key IS NOT DISTINCT FROM context_key.reported_name_key
    HAVING count(DISTINCT provider.provider_player_id) = 1
  ) selected
  ORDER BY selected.priority
  LIMIT 1
) provider_id ON true
LEFT JOIN current_player_enrichment current
  ON current.transfer_report_id = tr.id
LEFT JOIN provider_teams team
  ON team.id = current.current_provider_team_id
LEFT JOIN team_competition_mappings team_mapping
  ON team_mapping.provider_team_id = team.id
 AND team_mapping.superseded_at IS NULL
LEFT JOIN provider_competitions competition
  ON competition.id = team_mapping.provider_competition_id
LEFT JOIN provider_seasons season
  ON season.provider_competition_id = competition.id
 AND season.is_selected
LEFT JOIN LATERAL (
  SELECT jsonb_agg(alias.alias ORDER BY alias.id) AS rows
  FROM player_aliases alias
  WHERE alias.player_id = provider_id.player_id
    AND alias.provider = 'sofascore'
    AND alias.is_active
) aliases ON true
LEFT JOIN LATERAL (
  SELECT jsonb_agg(jsonb_build_object(
    'action', CASE identity_override.override_action
      WHEN 'reject_candidate' THEN 'reject'
      ELSE identity_override.override_action
    END,
    'provider_player_id', identity_override.provider_player_id,
    'effective_from', identity_override.effective_at,
    'revoked_at', identity_override.revoked_at,
    'active', identity_override.revoked_at IS NULL
  ) ORDER BY identity_override.id) AS rows
  FROM player_identity_overrides identity_override
  WHERE identity_override.provider = 'sofascore'
    AND identity_override.revoked_at IS NULL
    AND identity_override.effective_at <= CURRENT_TIMESTAMP
    AND identity_override.reported_name_key IS NOT DISTINCT FROM context_key.reported_name_key
    AND identity_override.current_club_key IS NOT DISTINCT FROM context_key.current_club_key
    AND identity_override.destination_club_key IS NOT DISTINCT FROM context_key.destination_club_key
) overrides ON true
LEFT JOIN LATERAL (
  SELECT attempt.status, attempt.started_at, attempt.next_retry_at,
    attempt.evidence->>'resolver_version' AS resolver_version
  FROM player_enrichment_attempts attempt
  WHERE attempt.transfer_report_id = tr.id
  ORDER BY attempt.started_at DESC, attempt.id DESC
  LIMIT 1
) latest_attempt ON true
ORDER BY tr.id;`.trim();
}

function persistEnrichmentSql() {
  return `
WITH input AS (
  SELECT $1::jsonb AS payload, $2::bigint AS workflow_run_id
),
items AS (
  SELECT item
  FROM input, jsonb_array_elements(input.payload->'items') item
),
expanded AS (
  SELECT item, report_id::text::bigint AS transfer_report_id
  FROM items, jsonb_array_elements_text(item->'report_ids') report_id
),
resolved_items AS (
  SELECT DISTINCT ON (item->'identity'->>'provider_player_id')
    item,
    item->'identity'->>'provider_player_id' AS provider_player_id,
    item->'identity'->>'stable_source_identifier' AS stable_source_identifier,
    item->'identity'->>'canonical_name' AS canonical_name
  FROM expanded
  WHERE item->'identity' IS NOT NULL
    AND item->>'status' IN ('fresh', 'cache_hit', 'partial', 'unsupported_competition', 'missing_season', 'club_conflict', 'unattached')
    AND item->'identity'->>'provider' = 'sofascore'
    AND item->'identity'->>'provider_player_id' ~ '^[0-9]+$'
  ORDER BY item->'identity'->>'provider_player_id', transfer_report_id
),
canonical_players AS (
  INSERT INTO players (identity_key, display_name, normalized_name)
  SELECT stable_source_identifier, canonical_name,
    COALESCE(NULLIF(item->'request_context'->>'reported_name_key', ''), lower(canonical_name))
  FROM resolved_items
  WHERE NULLIF(stable_source_identifier, '') IS NOT NULL
    AND NULLIF(canonical_name, '') IS NOT NULL
  ON CONFLICT (identity_key) DO UPDATE
  SET display_name = EXCLUDED.display_name,
      normalized_name = EXCLUDED.normalized_name
  RETURNING id, identity_key
),
provider_ids AS (
  INSERT INTO player_provider_ids (
    player_id, provider, provider_player_id, canonical_name, mapping_source,
    match_score, match_margin, resolver_version, evidence, verified_at, last_seen_at
  )
  SELECT player.id, 'sofascore', resolved.provider_player_id, resolved.canonical_name,
    CASE WHEN resolved.item->'identity'->>'resolver_version' = 'manual-identity-v1'
      THEN 'manual' ELSE 'automatic' END,
    NULLIF(resolved.item->'identity'->>'score', '')::numeric,
    NULLIF(resolved.item->'identity'->>'margin', '')::numeric,
    resolved.item->'identity'->>'resolver_version',
    jsonb_build_object('item_key', resolved.item->>'item_key'),
    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM resolved_items resolved
  JOIN canonical_players player
    ON player.identity_key = resolved.stable_source_identifier
  ON CONFLICT (provider, provider_player_id) DO UPDATE
  SET canonical_name = EXCLUDED.canonical_name,
      match_score = EXCLUDED.match_score,
      match_margin = EXCLUDED.match_margin,
      resolver_version = EXCLUDED.resolver_version,
      evidence = EXCLUDED.evidence,
      verified_at = EXCLUDED.verified_at,
      last_seen_at = EXCLUDED.last_seen_at
  RETURNING id, player_id, provider_player_id
),
report_resolutions AS (
  INSERT INTO transfer_report_player_resolutions (
    transfer_report_id, player_provider_id, resolution_source, match_score,
    match_margin, resolver_version, evidence, verified_at
  )
  SELECT expanded.transfer_report_id, provider_id.id,
    CASE WHEN expanded.item->'identity'->>'resolver_version' = 'manual-identity-v1'
      THEN 'manual' ELSE 'automatic' END,
    NULLIF(expanded.item->'identity'->>'score', '')::numeric,
    NULLIF(expanded.item->'identity'->>'margin', '')::numeric,
    expanded.item->'identity'->>'resolver_version',
    jsonb_build_object('item_key', expanded.item->>'item_key'),
    CURRENT_TIMESTAMP
  FROM expanded
  JOIN provider_ids provider_id
    ON provider_id.provider_player_id = expanded.item->'identity'->>'provider_player_id'
  WHERE expanded.item->>'status' IN ('fresh', 'cache_hit', 'partial', 'unsupported_competition', 'missing_season', 'club_conflict', 'unattached')
  ON CONFLICT (transfer_report_id) DO UPDATE
  SET player_provider_id = EXCLUDED.player_provider_id,
      resolution_source = EXCLUDED.resolution_source,
      match_score = EXCLUDED.match_score,
      match_margin = EXCLUDED.match_margin,
      resolver_version = EXCLUDED.resolver_version,
      evidence = EXCLUDED.evidence,
      verified_at = EXCLUDED.verified_at
  RETURNING transfer_report_id, player_provider_id
),
canonical_reports AS (
  UPDATE transfer_reports report
  SET player_id = provider_id.player_id
  FROM report_resolutions resolution
  JOIN provider_ids provider_id
    ON provider_id.id = resolution.player_provider_id
  WHERE report.id = resolution.transfer_report_id
  RETURNING report.id, report.player_id
),
aliases AS (
  INSERT INTO player_aliases (
    player_id, provider, alias, unicode_key, folded_key, alias_type, source, evidence
  )
  SELECT DISTINCT ON (
    canonical.player_id,
    expanded.item->'request_context'->>'reported_name_key'
  ) canonical.player_id, 'sofascore', report.reported_player_name,
    expanded.item->'request_context'->>'reported_name_key',
    expanded.item->'request_context'->>'reported_name_key',
    'report', 'transfer_report',
    jsonb_build_object('transfer_report_id', report.id::text)
  FROM expanded
  JOIN canonical_reports canonical ON canonical.id = expanded.transfer_report_id
  JOIN transfer_reports report ON report.id = expanded.transfer_report_id
  WHERE NULLIF(expanded.item->'request_context'->>'reported_name_key', '') IS NOT NULL
  ORDER BY canonical.player_id,
    expanded.item->'request_context'->>'reported_name_key',
    report.id,
    expanded.item->>'item_key'
  ON CONFLICT (player_id, provider, unicode_key) DO UPDATE
  SET alias = EXCLUDED.alias, evidence = EXCLUDED.evidence, is_active = true
  RETURNING id
),
teams AS (
  INSERT INTO provider_teams (
    provider, provider_team_id, canonical_name, unicode_key, folded_key,
    country, category, entity_scope, gender, age_group,
    raw_metadata_sha256, metadata_schema_version, last_seen_at
  )
  SELECT DISTINCT ON (item->'profile'->'current_club'->>'provider_team_id')
    'sofascore',
    item->'profile'->'current_club'->>'provider_team_id',
    item->'profile'->'current_club'->>'name',
    lower(item->'profile'->'current_club'->>'name'),
    lower(item->'profile'->'current_club'->>'name'),
    item->'profile'->'raw_payload'->'player'->'team'->'country'->>'name',
    item->'profile'->'raw_payload'->'player'->'team'->'category'->>'name',
    'club', 'men', 'senior',
    item->'profile'->>'raw_sha256', 'sofascore-adapter-v1',
    (item->'profile'->>'retrieved_at')::timestamptz
  FROM items
  WHERE item->'profile'->'current_club'->>'provider_team_id' ~ '^[0-9]+$'
    AND NULLIF(item->'profile'->'current_club'->>'name', '') IS NOT NULL
  ON CONFLICT (provider, provider_team_id) DO UPDATE
  SET canonical_name = EXCLUDED.canonical_name,
      unicode_key = EXCLUDED.unicode_key,
      folded_key = EXCLUDED.folded_key,
      country = EXCLUDED.country,
      category = EXCLUDED.category,
      raw_metadata_sha256 = EXCLUDED.raw_metadata_sha256,
      metadata_schema_version = EXCLUDED.metadata_schema_version,
      last_seen_at = EXCLUDED.last_seen_at
  RETURNING id, provider_team_id
),
competitions AS (
  INSERT INTO provider_competitions (
    provider, provider_unique_tournament_id, name, competition_kind,
    team_scope, gender, age_group, tier, eligibility, classification_source,
    rule_version, evidence, last_seen_at
  )
  SELECT DISTINCT ON (item->'statistics'->>'provider_unique_tournament_id')
    'sofascore',
    item->'statistics'->>'provider_unique_tournament_id',
    item->'statistics'->>'competition',
    'domestic_league', 'club', 'men', 'senior', 1, 'eligible', 'automatic',
    'competition-v1',
    jsonb_build_object('validated_by_service', true, 'item_key', item->>'item_key'),
    (item->'statistics'->>'retrieved_at')::timestamptz
  FROM items
  WHERE item->'statistics'->>'provider_unique_tournament_id' ~ '^[0-9]+$'
    AND NULLIF(item->'statistics'->>'competition', '') IS NOT NULL
  ON CONFLICT (provider, provider_unique_tournament_id) DO UPDATE
  SET name = EXCLUDED.name,
      evidence = EXCLUDED.evidence,
      last_seen_at = EXCLUDED.last_seen_at
  RETURNING id, provider_unique_tournament_id
),
incoming_seasons AS (
  SELECT DISTINCT ON (
    competition.id, item->'statistics'->>'provider_season_id'
  ) competition.id AS provider_competition_id,
    item->'statistics'->>'provider_season_id' AS provider_season_id,
    item->'statistics'->>'season' AS label,
    item->'statistics'->>'season_state' AS season_state,
    item->'statistics'->>'content_sha256' AS provider_list_sha256,
    (item->'statistics'->>'retrieved_at')::timestamptz AS retrieved_at
  FROM items
  JOIN competitions competition
    ON competition.provider_unique_tournament_id =
      item->'statistics'->>'provider_unique_tournament_id'
  WHERE item->'statistics'->>'provider_season_id' ~ '^[0-9]+$'
    AND item->'statistics'->>'season_state' IN ('active', 'latest_completed')
    AND NULLIF(item->'statistics'->>'season', '') IS NOT NULL
),
deselected_seasons AS (
  UPDATE provider_seasons season
  SET is_selected = false, superseded_at = CURRENT_TIMESTAMP
  FROM incoming_seasons incoming
  WHERE season.provider_competition_id = incoming.provider_competition_id
    AND season.is_selected
    AND season.provider_season_id <> incoming.provider_season_id
  RETURNING season.id
),
seasons AS (
  INSERT INTO provider_seasons (
    provider_competition_id, provider_season_id, label, observed_provider_order,
    season_state, is_selected, selection_source, provider_list_sha256,
    resolver_version, evidence, selected_at, retrieved_at, fresh_until
  )
  SELECT incoming.provider_competition_id, incoming.provider_season_id, incoming.label,
    0, incoming.season_state, true, 'automatic', incoming.provider_list_sha256,
    'season-v1', jsonb_build_object('validated_by_service', true),
    CURRENT_TIMESTAMP, incoming.retrieved_at, incoming.retrieved_at + interval '24 hours'
  FROM incoming_seasons incoming
  CROSS JOIN (SELECT count(*) FROM deselected_seasons) completed
  ON CONFLICT (provider_competition_id, provider_season_id) DO UPDATE
  SET label = EXCLUDED.label,
      season_state = EXCLUDED.season_state,
      is_selected = true,
      selected_at = EXCLUDED.selected_at,
      superseded_at = NULL,
      provider_list_sha256 = EXCLUDED.provider_list_sha256,
      evidence = EXCLUDED.evidence,
      retrieved_at = EXCLUDED.retrieved_at,
      fresh_until = EXCLUDED.fresh_until
  RETURNING id, provider_competition_id, provider_season_id
),
incoming_team_mappings AS (
  SELECT DISTINCT team.id AS provider_team_id, competition.id AS provider_competition_id
  FROM items
  JOIN teams team
    ON team.provider_team_id = item->'profile'->'current_club'->>'provider_team_id'
  JOIN competitions competition
    ON competition.provider_unique_tournament_id =
      item->'statistics'->>'provider_unique_tournament_id'
),
unambiguous_team_mappings AS (
  SELECT provider_team_id, min(provider_competition_id) AS provider_competition_id
  FROM incoming_team_mappings
  GROUP BY provider_team_id
  HAVING count(DISTINCT provider_competition_id) = 1
),
team_mappings AS (
  INSERT INTO team_competition_mappings (
    provider_team_id, provider_competition_id, mapping_source, rule_version,
    evidence, effective_from, verified_at, fresh_until
  )
  SELECT incoming.provider_team_id, incoming.provider_competition_id,
    'automatic', 'competition-v1',
    jsonb_build_object('validated_by_service', true),
    CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + interval '24 hours'
  FROM unambiguous_team_mappings incoming
  WHERE NOT EXISTS (
    SELECT 1 FROM team_competition_mappings existing
    WHERE existing.provider_team_id = incoming.provider_team_id
      AND existing.superseded_at IS NULL
      AND existing.provider_competition_id <> incoming.provider_competition_id
  )
  ON CONFLICT (provider_team_id) WHERE superseded_at IS NULL DO UPDATE
  SET provider_competition_id = EXCLUDED.provider_competition_id,
      rule_version = EXCLUDED.rule_version,
      evidence = EXCLUDED.evidence,
      verified_at = EXCLUDED.verified_at,
      fresh_until = EXCLUDED.fresh_until
  RETURNING id
),
profiles AS (
  INSERT INTO player_profile_snapshots (
    player_provider_id, canonical_name, current_provider_team_id, nationality,
    date_of_birth, age, primary_position, height_cm, preferred_foot,
    market_value, market_value_currency, stable_source_identifier,
    provider_retrieved_at, fresh_until, normalized_schema_version,
    resolver_version, content_sha256, raw_sha256, raw_cache_key,
    raw_profile, derived_fields
  )
  SELECT provider_id.id,
    item->'profile'->>'canonical_name',
    team.id,
    item->'profile'->>'nationality',
    NULLIF(item->'profile'->>'date_of_birth', '')::date,
    NULLIF(item->'profile'->>'age', '')::smallint,
    item->'profile'->>'primary_position',
    NULLIF(item->'profile'->>'height_cm', '')::smallint,
    item->'profile'->>'preferred_foot',
    NULLIF(item->'profile'->>'market_value', '')::numeric,
    NULLIF(item->'profile'->>'market_value_currency', ''),
    item->'identity'->>'stable_source_identifier',
    (item->'profile'->>'retrieved_at')::timestamptz,
    (item->'profile'->>'retrieved_at')::timestamptz + interval '24 hours',
    'enrichment-v1', item->'identity'->>'resolver_version',
    item->'profile'->>'content_sha256',
    item->'profile'->>'raw_sha256',
    item->'profile'->>'raw_cache_key',
    item->'profile'->'raw_payload',
    '{}'::jsonb
  FROM items
  JOIN provider_ids provider_id
    ON provider_id.provider_player_id = item->'identity'->>'provider_player_id'
  LEFT JOIN teams team
    ON team.provider_team_id = item->'profile'->'current_club'->>'provider_team_id'
  WHERE jsonb_typeof(item->'profile') = 'object'
  ON CONFLICT (player_provider_id, provider_retrieved_at, content_sha256) DO NOTHING
  RETURNING id
),
statistics AS (
  INSERT INTO player_season_stat_snapshots (
    player_provider_id, current_provider_team_id, provider_competition_id,
    provider_season_id, aggregation_scope, provider_retrieved_at, fresh_until,
    normalized_schema_version, resolver_version, content_sha256, raw_sha256,
    raw_cache_key, raw_statistics, derived_fields, appearances, starts,
    minutes_played, minutes_per_appearance, goals, expected_goals, assists,
    expected_assists, average_rating, yellow_cards, red_cards,
    goalkeeper_clean_sheets, goalkeeper_saves
  )
  SELECT provider_id.id, team.id, competition.id, season.id,
    item->'statistics'->>'scope',
    (item->'statistics'->>'retrieved_at')::timestamptz,
    (item->'statistics'->>'retrieved_at')::timestamptz + interval '12 hours',
    'enrichment-v1', item->'identity'->>'resolver_version',
    item->'statistics'->>'content_sha256',
    item->'statistics'->>'raw_sha256',
    item->'statistics'->>'raw_cache_key',
    item->'statistics'->'raw_payload',
    '{}'::jsonb,
    NULLIF(item->'statistics'->>'appearances', '')::integer,
    NULLIF(item->'statistics'->>'starts', '')::integer,
    NULLIF(item->'statistics'->>'minutes_played', '')::integer,
    NULLIF(item->'statistics'->>'minutes_per_game', '')::numeric,
    NULLIF(item->'statistics'->>'goals', '')::integer,
    NULLIF(item->'statistics'->>'expected_goals', '')::numeric,
    NULLIF(item->'statistics'->>'assists', '')::integer,
    NULLIF(item->'statistics'->>'expected_assists', '')::numeric,
    NULLIF(item->'statistics'->>'average_rating', '')::numeric,
    NULLIF(item->'statistics'->>'yellow_cards', '')::integer,
    NULLIF(item->'statistics'->>'red_cards', '')::integer,
    NULLIF(item->'statistics'->>'clean_sheets', '')::integer,
    NULLIF(item->'statistics'->>'saves', '')::integer
  FROM items
  JOIN provider_ids provider_id
    ON provider_id.provider_player_id = item->'identity'->>'provider_player_id'
  JOIN teams team
    ON team.provider_team_id = item->'profile'->'current_club'->>'provider_team_id'
  JOIN competitions competition
    ON competition.provider_unique_tournament_id =
      item->'statistics'->>'provider_unique_tournament_id'
  JOIN seasons season
    ON season.provider_competition_id = competition.id
   AND season.provider_season_id = item->'statistics'->>'provider_season_id'
  WHERE jsonb_typeof(item->'statistics') = 'object'
    AND item->'statistics'->>'scope' = 'selected_domestic_league_all_clubs'
  ON CONFLICT (
    player_provider_id, provider_season_id, aggregation_scope,
    provider_retrieved_at, content_sha256
  ) DO NOTHING
  RETURNING id
),
attempts AS (
  INSERT INTO player_enrichment_attempts (
    request_key, batch_request_key, item_key, workflow_run_id,
    transfer_report_id, player_id, player_provider_id, status, retryable,
    next_retry_at, match_score, match_margin, provider_call_count,
    cache_hit_count, request_context, evidence, error_code, error_fingerprint,
    error_message, started_at, completed_at
  )
  SELECT
    (input.payload->>'request_id') || ':' || (expanded.item->>'item_key') || ':' ||
      expanded.transfer_report_id::text,
    input.payload->>'request_id',
    expanded.item->>'item_key',
    input.workflow_run_id,
    expanded.transfer_report_id,
    canonical.player_id,
    provider_id.id,
    CASE
      WHEN expanded.item->>'status' = 'partial'
       AND expanded.item->'warning_codes' ? 'unattached' THEN 'unattached'
      WHEN expanded.item->>'status' = 'partial'
       AND expanded.item->'warning_codes' ? 'missing_season' THEN 'missing_season'
      ELSE expanded.item->>'status'
    END,
    CASE WHEN expanded.item->>'status' IN ('unresolved', 'ambiguous')
      THEN true ELSE COALESCE((expanded.item->>'retryable')::boolean, false) END,
    CASE
      WHEN expanded.item->>'status' IN ('unresolved', 'ambiguous')
        THEN CURRENT_TIMESTAMP + interval '24 hours'
      WHEN COALESCE((expanded.item->>'retryable')::boolean, false)
        THEN CURRENT_TIMESTAMP + interval '10 minutes'
      ELSE NULL
    END,
    NULLIF(expanded.item->'identity'->>'score', '')::numeric,
    NULLIF(expanded.item->'identity'->>'margin', '')::numeric,
    COALESCE((expanded.item->>'provider_calls')::integer, 0),
    COALESCE((expanded.item->>'cache_hits')::integer, 0),
    COALESCE(expanded.item->'request_context', '{}'::jsonb),
    jsonb_build_object(
      'warning_codes', COALESCE(expanded.item->'warning_codes', '[]'::jsonb),
      'candidate_count', CASE
        WHEN jsonb_typeof(expanded.item->'candidates') = 'array'
          THEN jsonb_array_length(expanded.item->'candidates')
        ELSE 0
      END,
      'candidates', CASE
        WHEN jsonb_typeof(expanded.item->'candidates') = 'array'
          THEN expanded.item->'candidates'
        ELSE '[]'::jsonb
      END,
      'resolver_version', expanded.item->>'resolver_version'
    ),
    expanded.item->'error'->>'code',
    CASE WHEN expanded.item->'error'->>'code' IS NULL THEN NULL
      ELSE (expanded.item->>'item_key') || ':' || (expanded.item->'error'->>'code') END,
    expanded.item->'error'->>'code',
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP
  FROM input
  CROSS JOIN expanded
  LEFT JOIN canonical_reports canonical
    ON canonical.id = expanded.transfer_report_id
  LEFT JOIN provider_ids provider_id
    ON provider_id.provider_player_id =
      expanded.item->'identity'->>'provider_player_id'
  CROSS JOIN (
    SELECT count(*) FROM aliases
  ) alias_completion
  CROSS JOIN (
    SELECT count(*) FROM team_mappings
  ) mapping_completion
  CROSS JOIN (
    SELECT count(*) FROM profiles
  ) profile_completion
  CROSS JOIN (
    SELECT count(*) FROM statistics
  ) statistics_completion
  ON CONFLICT (request_key) DO UPDATE
  SET status = EXCLUDED.status,
      retryable = EXCLUDED.retryable,
      next_retry_at = EXCLUDED.next_retry_at,
      provider_call_count = EXCLUDED.provider_call_count,
      cache_hit_count = EXCLUDED.cache_hit_count,
      evidence = EXCLUDED.evidence,
      error_code = EXCLUDED.error_code,
      error_fingerprint = EXCLUDED.error_fingerprint,
      error_message = EXCLUDED.error_message,
      completed_at = EXCLUDED.completed_at
  RETURNING id
)
SELECT true AS enrichment_persisted,
  (SELECT count(*) FROM attempts)::integer AS attempt_count,
  input.payload->>'request_id' AS request_id
FROM input;`.trim();
}

function candidatesSql() {
  return `
WITH pending_candidates AS (
  SELECT r.id::text AS revision_id, r.snapshot,
    s.priority_rank, s.reliability_score, s.is_official, s.username AS source_username, s.display_name AS source_name,
    p.post_url, p.posted_at,
    dd.idempotency_key AS pending_idempotency_key,
    dd.window_started_at AS pending_window_started_at,
    dd.window_ended_at AS pending_window_ended_at,
    dd.request_payload AS pending_request_payload,
    NULL::jsonb AS enrichment
  FROM digest_deliveries dd
  JOIN digest_items di ON di.digest_delivery_id = dd.id
  JOIN transfer_report_revisions r ON r.id = di.transfer_report_revision_id
  JOIN transfer_reports tr ON tr.id = r.transfer_report_id
  JOIN transfer_report_sources trs ON trs.transfer_report_id = tr.id AND trs.is_preferred
  JOIN raw_posts p ON p.id = trs.raw_post_id
  JOIN source_accounts s ON s.id = p.source_account_id
  WHERE dd.status = 'pending'
),
latest_revisions AS (
  SELECT DISTINCT ON (transfer_report_id) id, transfer_report_id, snapshot
  FROM transfer_report_revisions
  ORDER BY transfer_report_id, revision_number DESC, id DESC
),
fresh_candidates AS (
  SELECT r.id::text AS revision_id, r.snapshot,
  s.priority_rank, s.reliability_score, s.is_official, s.username AS source_username, s.display_name AS source_name,
  p.post_url, p.posted_at,
  NULL::text AS pending_idempotency_key,
  NULL::timestamptz AS pending_window_started_at,
  NULL::timestamptz AS pending_window_ended_at,
  NULL::jsonb AS pending_request_payload,
  CASE WHEN $3::text = 'active' THEN NULLIF(jsonb_strip_nulls(jsonb_build_object(
    'profile', CASE WHEN
      current.profile_fresh_until > CURRENT_TIMESTAMP
      OR (
        current.profile_retrieved_at >= CURRENT_TIMESTAMP - interval '72 hours'
        AND latest_attempt.status IN (
          'provider_failure', 'rate_limited', 'timeout', 'schema_failure', 'deferred'
        )
        AND latest_attempt.started_at >= current.profile_fresh_until
      )
      OR (
        current.current_provider_team_id IS NULL
        AND latest_attempt.status = 'unattached'
        AND current.profile_retrieved_at >= CURRENT_TIMESTAMP - interval '7 days'
      )
    THEN jsonb_strip_nulls(jsonb_build_object(
      'snapshot_id', current.profile_snapshot_id::text,
      'canonical_name', current.canonical_name,
      'current_club_name', current.current_club_name,
      'nationality', current.nationality,
      'date_of_birth', current.date_of_birth,
      'age', current.age,
      'primary_position', current.primary_position,
      'height_cm', current.height_cm,
      'preferred_foot', current.preferred_foot,
      'market_value', current.market_value,
      'market_value_currency', current.market_value_currency,
      'retrieved_at', current.profile_retrieved_at,
      'fresh_until', current.profile_fresh_until,
      'stale', current.profile_fresh_until <= CURRENT_TIMESTAMP
    )) ELSE NULL END,
    'statistics', CASE WHEN
      current.statistics_fresh_until > CURRENT_TIMESTAMP
      OR (
        current.statistics_retrieved_at >= CURRENT_TIMESTAMP - interval '72 hours'
        AND latest_attempt.status IN (
          'provider_failure', 'rate_limited', 'timeout', 'schema_failure', 'deferred'
        )
        AND latest_attempt.started_at >= current.statistics_fresh_until
      )
    THEN jsonb_strip_nulls(jsonb_build_object(
      'snapshot_id', current.statistics_snapshot_id::text,
      'competition_name', current.competition_name,
      'season_label', current.season_label,
      'season_state', current.season_state,
      'scope', current.aggregation_scope,
      'appearances', current.appearances,
      'starts', current.starts,
      'minutes_played', current.minutes_played,
      'minutes_per_appearance', current.minutes_per_appearance,
      'goals', current.goals,
      'expected_goals', current.expected_goals,
      'assists', current.assists,
      'expected_assists', current.expected_assists,
      'average_rating', current.average_rating,
      'yellow_cards', current.yellow_cards,
      'red_cards', current.red_cards,
      'goalkeeper_clean_sheets', current.goalkeeper_clean_sheets,
      'goalkeeper_saves', current.goalkeeper_saves,
      'retrieved_at', current.statistics_retrieved_at,
      'fresh_until', current.statistics_fresh_until,
      'stale', current.statistics_fresh_until <= CURRENT_TIMESTAMP
    )) ELSE NULL END
  )), '{}'::jsonb) ELSE NULL END AS enrichment
FROM latest_revisions r
JOIN transfer_reports tr ON tr.id = r.transfer_report_id
JOIN transfer_report_sources trs ON trs.transfer_report_id = tr.id AND trs.is_preferred
JOIN raw_posts p ON p.id = trs.raw_post_id
JOIN source_accounts s ON s.id = p.source_account_id
LEFT JOIN digest_items di ON di.transfer_report_revision_id = r.id
LEFT JOIN current_player_enrichment current
  ON current.transfer_report_id = tr.id
LEFT JOIN LATERAL (
  SELECT attempt.status, attempt.started_at
  FROM player_enrichment_attempts attempt
  WHERE attempt.transfer_report_id = tr.id
  ORDER BY attempt.started_at DESC, attempt.id DESC
  LIMIT 1
) latest_attempt ON true
WHERE di.id IS NULL
  AND tr.last_reported_at >= $1::timestamptz
  AND tr.last_reported_at <= $2::timestamptz
  AND NOT EXISTS (SELECT 1 FROM pending_candidates)
),
candidates AS (
  SELECT * FROM pending_candidates
  UNION ALL
  SELECT * FROM fresh_candidates
),
limited_candidates AS (
  SELECT * FROM candidates
  ORDER BY priority_rank ASC, posted_at DESC
  LIMIT 100
),
sent_history AS (
  SELECT COALESCE(jsonb_agg(jsonb_build_object('snapshot', sent_revision.snapshot, 'sent_at', sent_delivery.sent_at)), '[]'::jsonb) AS payload
  FROM digest_items sent_item
  JOIN digest_deliveries sent_delivery ON sent_delivery.id = sent_item.digest_delivery_id
  JOIN transfer_report_revisions sent_revision ON sent_revision.id = sent_item.transfer_report_revision_id
  WHERE sent_delivery.status = 'sent'
    AND sent_delivery.sent_at >= CURRENT_TIMESTAMP - interval '7 days'
)
SELECT 'sent_history'::text AS row_type, payload FROM sent_history
UNION ALL
SELECT 'candidate'::text AS row_type, to_jsonb(limited_candidates) AS payload FROM limited_candidates;`.trim();
}

function reserveDigestSql() {
  return `
WITH input AS (SELECT $1::jsonb AS payload),
delivery AS (
  INSERT INTO digest_deliveries (
    idempotency_key, channel_key, window_started_at, window_ended_at,
    status, attempt_count, request_payload, first_attempted_at, last_attempted_at
  )
  SELECT payload->>'idempotency_key', 'transfers', (payload->>'window_started_at')::timestamptz, (payload->>'window_ended_at')::timestamptz,
    'sending', 1, payload->'discord_payload', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM input
  ON CONFLICT (idempotency_key) DO UPDATE
  SET status = 'sending', attempt_count = digest_deliveries.attempt_count + 1,
      first_attempted_at = COALESCE(digest_deliveries.first_attempted_at, CURRENT_TIMESTAMP),
      last_attempted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
  WHERE digest_deliveries.status = 'pending'
  RETURNING id, status, request_payload
),
claimed AS (
  INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
  SELECT (SELECT id FROM delivery), revision_id::bigint, position::smallint
  FROM input, jsonb_array_elements_text(input.payload->'revision_ids') WITH ORDINALITY AS selected(revision_id, position)
  WHERE (SELECT status FROM delivery) = 'sending'
  ON CONFLICT (transfer_report_revision_id) DO NOTHING
  RETURNING id
)
SELECT id::text AS digest_delivery_id, status, request_payload FROM delivery
WHERE EXISTS (SELECT 1 FROM claimed)
   OR EXISTS (SELECT 1 FROM digest_items WHERE digest_delivery_id = delivery.id);`.trim();
}

function finalizeDeliverySql() {
  return `
UPDATE digest_deliveries
SET status = CASE
      WHEN $2::integer BETWEEN 200 AND 299 THEN 'sent'
      WHEN $2::integer = 0 THEN 'unknown'
      ELSE 'failed'
    END,
    discord_message_id = CASE WHEN $2::integer BETWEEN 200 AND 299 THEN $3 ELSE NULL END,
    response_payload = $4::jsonb,
    sent_at = CASE WHEN $2::integer BETWEEN 200 AND 299 THEN CURRENT_TIMESTAMP ELSE NULL END
WHERE id = $1::bigint
RETURNING id::text AS digest_delivery_id, status, discord_message_id;`.trim();
}

function runRegistrationSql() {
  return `
WITH next_attempt AS (
  SELECT COALESCE(max(attempt_number), 0) + 1 AS attempt_number
  FROM workflow_runs WHERE workflow_name = 'football-transfer-monitor' AND logical_run_key = $2
)
INSERT INTO workflow_runs (workflow_name, external_execution_id, logical_run_key, attempt_number, status, metadata)
VALUES ('football-transfer-monitor', $1, $2, (SELECT attempt_number FROM next_attempt), 'running', $3::jsonb)
ON CONFLICT (workflow_name, external_execution_id) DO UPDATE
SET metadata = EXCLUDED.metadata
RETURNING id::text AS workflow_run_id, external_execution_id, logical_run_key;`.trim();
}

function runtimeHelpers() {
  return `
${entityAliasHelpers()}
const normalize = normalizeAlias;
const unicodeKey = (value) => String(value ?? '').normalize('NFKC').toLocaleLowerCase('und').replace(/[\\p{P}\\p{Z}]+/gu, ' ').trim().replace(/\\s+/gu, ' ');
const namedKey = (value) => {
  const normalized = unicodeKey(value);
  return normalized && !/^(not reported|unknown|n a)$/u.test(normalized) ? normalized : null;
};
const key = (report) => [report.player_name, report.current_club_name || 'unknown', report.destination_club_name || 'unknown'].map((value) => normalize(value).replace(/\\s/g, '-')).join('|');
const precedence = { contract_renewal: 6, rejected_failed: 5, loan: 4, official_confirmed: 3, advanced_negotiations: 2, rumor: 1 };
const compareSource = (left, right) => (left.source.priority_rank - right.source.priority_rank) || (right.source.reliability_score - left.source.reliability_score) || String(left.posted_at).localeCompare(String(right.posted_at));
const sha256 = (value) => {
  const input = unescape(encodeURIComponent(JSON.stringify(value)));
  const bytes = Array.from(input, (character) => character.charCodeAt(0));
  const bitLength = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  for (let index = 7; index >= 0; index -= 1) bytes.push(Math.floor(bitLength / 2 ** (index * 8)) & 0xff);
  const constants = [0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2];
  const hash = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const rotateRight = (number, amount) => (number >>> amount) | (number << (32 - amount));
  for (let offset = 0; offset < bytes.length; offset += 64) {
    const words = new Array(64);
    for (let index = 0; index < 16; index += 1) words[index] = (bytes[offset + index * 4] << 24) | (bytes[offset + index * 4 + 1] << 16) | (bytes[offset + index * 4 + 2] << 8) | bytes[offset + index * 4 + 3];
    for (let index = 16; index < 64; index += 1) {
      const small0 = rotateRight(words[index - 15], 7) ^ rotateRight(words[index - 15], 18) ^ (words[index - 15] >>> 3);
      const small1 = rotateRight(words[index - 2], 17) ^ rotateRight(words[index - 2], 19) ^ (words[index - 2] >>> 10);
      words[index] = (words[index - 16] + small0 + words[index - 7] + small1) | 0;
    }
    let [a, b, c, d, e, f, g, h] = hash;
    for (let index = 0; index < 64; index += 1) {
      const large1 = rotateRight(e, 6) ^ rotateRight(e, 11) ^ rotateRight(e, 25);
      const choice = (e & f) ^ (~e & g);
      const temporary1 = (h + large1 + choice + constants[index] + words[index]) | 0;
      const large0 = rotateRight(a, 2) ^ rotateRight(a, 13) ^ rotateRight(a, 22);
      const majority = (a & b) ^ (a & c) ^ (b & c);
      const temporary2 = (large0 + majority) | 0;
      [h, g, f, e, d, c, b, a] = [g, f, e, (d + temporary1) | 0, c, b, a, (temporary1 + temporary2) | 0];
    }
    hash[0] = (hash[0] + a) | 0; hash[1] = (hash[1] + b) | 0; hash[2] = (hash[2] + c) | 0; hash[3] = (hash[3] + d) | 0;
    hash[4] = (hash[4] + e) | 0; hash[5] = (hash[5] + f) | 0; hash[6] = (hash[6] + g) | 0; hash[7] = (hash[7] + h) | 0;
  }
  return hash.map((number) => (number >>> 0).toString(16).padStart(8, '0')).join('');
};`;
}

function entityAliasHelpers() {
  if (!entityAliases) throw new Error('Entity aliases have not been loaded');
  return `
const entityAliases = ${JSON.stringify(entityAliases)};
const normalizeAlias = (value) => String(value ?? '').normalize('NFKD').replace(/[\\u0300-\\u036f]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim().replace(/\\s+/g, ' ');
const canonicalEntity = (value, aliases) => typeof value === 'string' ? aliases[normalizeAlias(value)] ?? value.trim() : value;
const canonicalizeReport = (report) => ({
  ...report,
  player_name: canonicalEntity(report.player_name, entityAliases.players),
  current_club_name: canonicalEntity(report.current_club_name, entityAliases.clubs),
  former_club_name: canonicalEntity(report.former_club_name, entityAliases.clubs),
  destination_club_name: canonicalEntity(report.destination_club_name, entityAliases.clubs),
});`;
}

function rapidApiParserCode() {
  return `
const inputs = $input.all();
const requests = inputs.some((item) => !item.json.source) ? $('Build RapidAPI request').all() : [];
const context = $('Create run context').isExecuted ? $('Create run context').first().json : $('Create sample run context').first().json;
const collectionCutoffAt = Date.parse(context.collection_cutoff_at);
const collectionStartedAt = Date.parse(context.collection_started_at);
return inputs.flatMap((item, index) => {
  const requestIndex = item.pairedItem?.item ?? index;
  const request = item.json.source ? { source: item.json.source } : requests[requestIndex]?.json;
  if (!request?.source) throw new Error('Missing RapidAPI request metadata for response item ' + index);
  const response = item.json.body ?? item.json;
  const found = [], walked = new Set(), seen = new Set();
  const walk = (value) => {
    if (!value || typeof value !== 'object' || walked.has(value)) return;
    walked.add(value);
    const text = value?.note_tweet?.note_tweet_results?.result?.text ?? value?.legacy?.full_text ?? value?.legacy?.text;
    const id = String(value?.rest_id ?? value?.legacy?.id_str ?? value?.id_str ?? '');
    if (/^\\d+$/.test(id) && text) found.push(value);
    Object.values(value).forEach(walk);
  };
  walk(response);
  return found.flatMap((tweet) => {
    const external_post_id = String(tweet?.rest_id ?? tweet?.legacy?.id_str ?? tweet?.id_str ?? '');
    const text = tweet?.note_tweet?.note_tweet_results?.result?.text ?? tweet?.legacy?.full_text ?? tweet?.legacy?.text;
    if (!external_post_id || !text || seen.has(external_post_id) || tweet?.legacy?.retweeted_status_result || /^RT\\s+@/i.test(text)) return [];
    const date = new Date(tweet?.legacy?.created_at ?? tweet?.created_at);
    if (Number.isNaN(date.valueOf()) || date.valueOf() < collectionCutoffAt || date.valueOf() > collectionStartedAt) return [];
    seen.add(external_post_id);
    const quote = tweet?.quoted_status_result?.result?.legacy?.full_text;
    return [{ json: {
      params: [request.source.external_account_id, external_post_id, 'https://x.com/' + request.source.username + '/status/' + external_post_id, quote ? text + '\\n\\nQuoted post:\\n' + quote : text, date.toISOString(), JSON.stringify(tweet), request.source.username, request.source.display_name, request.source.priority_rank, request.source.reliability_score, request.source.is_official],
    } }];
  });
});`;
}

function twscrapeParserCode() {
  return `
const request = $('Build twscrape collect request').first().json;
const sources = new Map((request.sources ?? []).map((source) => [String(source.source_id), source]));
const response = $input.first()?.json?.body ?? $input.first()?.json ?? {};
const posts = Array.isArray(response?.posts) ? response.posts : [];
const errors = Array.isArray(response?.errors) ? response.errors : [];
const sourceIds = [...sources.keys()];
const failedSourceIds = new Set(errors.map((error) => String(error?.source_id ?? '')).filter(Boolean));
if (!posts.length && sourceIds.length && sourceIds.every((sourceId) => failedSourceIds.has(sourceId))) {
  const codes = [...new Set(errors.map((error) => String(error?.code ?? '')).filter(Boolean))].sort();
  throw new Error('twscrape collection failed for ' + sourceIds.length + ' source(s)' + (codes.length ? ': ' + codes.join(', ') : ''));
}
const context = $('Create run context').isExecuted ? $('Create run context').first().json : $('Create sample run context').first().json;
const collectionCutoffAt = Date.parse(context.collection_cutoff_at);
const collectionStartedAt = Date.parse(context.collection_started_at);
const seen = new Set();
return posts.flatMap((post) => {
  const source = sources.get(String(post?.source_id ?? ''));
  const externalPostId = String(post?.external_post_id ?? '');
  const xUserId = String(post?.x_user_id ?? '');
  const content = typeof post?.content === 'string' ? post.content.trim() : '';
  const date = new Date(post?.posted_at);
  if (!source || xUserId !== String(source.external_account_id) || !/^\\d+$/.test(externalPostId) || !content || seen.has(externalPostId) || /^RT\\s+@/i.test(content) || Number.isNaN(date.valueOf()) || date.valueOf() < collectionCutoffAt || date.valueOf() > collectionStartedAt) return [];
  seen.add(externalPostId);
  const postUrl = typeof post?.post_url === 'string' && post.post_url.startsWith('https://')
    ? post.post_url
    : 'https://x.com/' + source.username + '/status/' + externalPostId;
  const rawPayload = post?.raw_payload && typeof post.raw_payload === 'object' ? post.raw_payload : {};
  return [{ json: {
    params: [String(source.external_account_id), externalPostId, postUrl, content, date.toISOString(), JSON.stringify(rawPayload), source.username, source.display_name, source.priority_rank, source.reliability_score, source.is_official],
  } }];
});`;
}

function qwenParseCode() {
  return `
${entityAliasHelpers()}
const requests = $('Build Qwen request').all();
const required = ${JSON.stringify(['player_name', 'player_identity_hint', 'current_club_name', 'former_club_name', 'destination_club_name', 'classification', 'move_type', 'fee_amount', 'fee_currency', 'add_ons_amount', 'add_ons_currency', 'release_clause_amount', 'release_clause_currency', 'contract_length_months', 'contract_expires_on', 'loan_ends_on', 'has_option_to_buy', 'has_obligation_to_buy', 'sell_on_percentage', 'medical_status', 'agreement_status', 'is_huge_rumor', 'is_digest_worthy', 'confidence'])};
const classes = ${JSON.stringify(['official_confirmed', 'advanced_negotiations', 'rumor', 'rejected_failed', 'contract_renewal', 'loan'])};
return $input.all().flatMap((item, index) => {
  const requestIndex = item.pairedItem?.item ?? index;
  const request = requests[requestIndex]?.json;
  if (!request?.raw_post_id) throw new Error('Missing Qwen request metadata for response item ' + index);
  const response = item.json.body ?? item.json;
  const content = response?.choices?.[0]?.message?.content;
  let parsed;
  try { parsed = typeof content === 'string' ? JSON.parse(content) : content; } catch { parsed = null; }
  const nullableClub = (value) => typeof value === 'string' && /^(not[ _-]?reported|unknown|n\\/?a)$/i.test(value.trim()) ? null : value;
  if (parsed && Array.isArray(parsed.reports)) parsed.reports = parsed.reports.map((report) => canonicalizeReport({ ...report, current_club_name: nullableClub(report.current_club_name), former_club_name: nullableClub(report.former_club_name), destination_club_name: nullableClub(report.destination_club_name) }));
  const valid = parsed && typeof parsed.transfer_related === 'boolean' && Array.isArray(parsed.reports) && parsed.reports.every((report) => report && Object.keys(report).length === required.length && required.every((field) => field in report) && typeof report.player_name === 'string' && report.player_name.trim().length > 0 && classes.includes(report.classification) && typeof report.is_huge_rumor === 'boolean' && typeof report.is_digest_worthy === 'boolean' && Number.isFinite(report.confidence) && report.confidence >= 0 && report.confidence <= 1);
  if (!valid) {
    return [{ json: { valid: false, params: [request.raw_post_id, 'qwen-schema-' + request.external_post_id, 'Malformed or schema-invalid Qwen response', JSON.stringify({ response }), 'x:' + request.external_post_id, 1000] } }];
  }
  if (!parsed.transfer_related) return [{ json: { valid: true, ignored: true, raw_post_id: request.raw_post_id, params: [request.raw_post_id] } }];
  return parsed.reports.map((report) => ({ json: { valid: true, ignored: false, report: { ...report, raw_post_id: request.raw_post_id, post_url: request.post_url, posted_at: request.posted_at, source: request.source } } }));
});`;
}

function mergeCode() {
  return `
${runtimeHelpers()}
const groups = new Map();
for (const item of $input.all()) {
  const report = item.json.report ? canonicalizeReport(item.json.report) : null;
  if (!report) continue;
  const groupKey = key(report);
  groups.set(groupKey, [...(groups.get(groupKey) ?? []), report]);
}
const outputs = [];
for (const reports of groups.values()) {
  reports.sort(compareSource);
  const best = reports[0];
  const merged = { ...best };
  const conflicts = {};
  for (const field of Object.keys(best)) {
    if (['raw_post_id', 'post_url', 'posted_at', 'source'].includes(field)) continue;
    const values = reports.map((report) => report[field]).filter((value) => value !== null && value !== undefined && value !== '');
    if (values.length) merged[field] = values[0];
    if (new Set(values.map((value) => JSON.stringify(value))).size > 1) conflicts[field] = values;
  }
  merged.classification = reports.map((report) => report.classification).sort((a, b) => precedence[b] - precedence[a])[0];
  merged.confidence = Math.max(...reports.map((report) => report.confidence));
  merged.dedupe_key = key(merged);
  merged.first_reported_at = reports.map((report) => report.posted_at).sort()[0];
  merged.last_reported_at = reports.map((report) => report.posted_at).sort().at(-1);
  const snapshot = Object.fromEntries(${JSON.stringify(['player_name', 'player_identity_hint', 'current_club_name', 'former_club_name', 'destination_club_name', 'classification', 'move_type', 'fee_amount', 'fee_currency', 'add_ons_amount', 'add_ons_currency', 'release_clause_amount', 'release_clause_currency', 'contract_length_months', 'contract_expires_on', 'loan_ends_on', 'has_option_to_buy', 'has_obligation_to_buy', 'sell_on_percentage', 'medical_status', 'agreement_status', 'is_huge_rumor', 'is_digest_worthy', 'confidence'])}.map((field) => [field, merged[field] ?? null]));
  snapshot.dedupe_key = merged.dedupe_key;
  const payload = {
    ...snapshot,
    player_identity_key: normalize(merged.player_name).replace(/\\s/g, '-'),
    normalized_player_name: normalize(merged.player_name),
    first_reported_at: merged.first_reported_at,
    last_reported_at: merged.last_reported_at,
    normalized_data: { conflicts, former_club_name: merged.former_club_name ?? null, reported_name_key: unicodeKey(merged.player_name), current_club_key: namedKey(merged.current_club_name), destination_club_key: namedKey(merged.destination_club_name) },
    preferred_raw_post_id: String(best.raw_post_id),
    sources: reports.map((report) => ({ raw_post_id: String(report.raw_post_id), posted_at: report.posted_at, post_url: report.post_url, source: report.source })),
    snapshot,
    content_sha256: sha256(Object.fromEntries(Object.entries(snapshot).filter(([field]) => field !== 'is_digest_worthy'))),
  };
  outputs.push({ json: { params: [JSON.stringify(payload)] } });
}
return outputs;`;
}

function prepareEnrichmentBatchCode() {
  return `
const selected = String($env.PLAYER_ENRICHMENT_MODE ?? 'off').trim().toLowerCase();
const mode = ['shadow', 'active'].includes(selected) ? selected : 'off';
const reportIds = [...new Set($input.all()
  .map((item) => String(item.json.transfer_report_id ?? ''))
  .filter((value) => /^\\d+$/.test(value)))];
const workflowRunId = $('Register workflow run').isExecuted
  ? $('Register workflow run').first().json.workflow_run_id
  : $('Register sample workflow run').first().json.workflow_run_id;
return [{ json: {
  mode,
  workflow_run_id: String(workflowRunId),
  params: [JSON.stringify(reportIds), String(workflowRunId)],
} }];`;
}

function buildEnrichmentRequestCode() {
  return `
${entityAliasHelpers()}
const prepared = $('Prepare enrichment batch query').first().json;
const mode = ['shadow', 'active'].includes(prepared.mode) ? prepared.mode : 'off';
const now = Date.now();
const parseValue = (value, fallback) => {
  if (value === null || value === undefined) return fallback;
  if (typeof value !== 'string') return value;
  try { return JSON.parse(value); } catch { return fallback; }
};
const unicodeKey = (value) => String(value ?? '')
  .normalize('NFKC')
  .toLocaleLowerCase('und')
  .replace(/[\\p{P}\\p{Z}]+/gu, ' ')
  .trim()
  .replace(/\\s+/gu, ' ');
const namedContext = (value) => {
  const normalized = unicodeKey(value);
  return normalized && !/^(not reported|unknown|n a)$/u.test(normalized) ? normalized : null;
};
const fresh = (value) => {
  const timestamp = Date.parse(String(value ?? ''));
  return Number.isFinite(timestamp) && timestamp > now;
};
const preparedContexts = [];
if (mode !== 'off') {
  for (const input of $input.all()) {
    const context = input.json ?? {};
    const reportId = String(context.transfer_report_id ?? '');
    const reportedName = typeof context.reported_player_name === 'string' ? context.reported_player_name.trim() : '';
    const providerId = String(context.provider_player_id ?? '');
    if (!/^\\d+$/.test(reportId) || !reportedName || (providerId && !/^\\d+$/.test(providerId))) continue;
    const aliases = parseValue(context.aliases, []);
    const overrides = parseValue(context.identity_overrides, []);
    const latestStatus = String(context.latest_attempt_status ?? '');
    const latestStarted = Date.parse(String(context.latest_attempt_started_at ?? ''));
    const retryAt = Date.parse(String(context.latest_attempt_next_retry_at ?? ''));
    const canonicalCurrentClub = canonicalEntity(context.current_club_name, entityAliases.clubs);
    const globallyCanonicalName = canonicalEntity(reportedName, entityAliases.players);
    const canonicalReportedName = entityAliases.enrichment_player_aliases[normalizeAlias(reportedName) + '|' + normalizeAlias(canonicalCurrentClub)] ?? globallyCanonicalName;
    const canonicalFormerClub = canonicalEntity(context.former_club_name, entityAliases.clubs);
    const canonicalDestinationClub = canonicalEntity(context.destination_club_name, entityAliases.clubs);
    const currentClubKey = namedContext(canonicalCurrentClub);
    const formerClubKey = namedContext(canonicalFormerClub);
    const destinationClubKey = namedContext(canonicalDestinationClub);
    const destinationEligible = destinationClubKey !== null;
    const clubKey = currentClubKey ?? destinationClubKey ?? formerClubKey;
    const reportedNameKey = unicodeKey(canonicalReportedName);
    if (!providerId && (!reportedNameKey || !clubKey)) continue;
    const groupedItemKey = providerId ? 'provider:' + providerId : 'name:' + reportedNameKey + '|club:' + clubKey;
    const forceResolverRetry = context.force_resolver_retry === true;
    const hardBackoff = !forceResolverRetry && Number.isFinite(retryAt) && retryAt > now;
    const ambiguityCooldown = !providerId
      && !forceResolverRetry
      && ['ambiguous', 'unresolved'].includes(latestStatus)
      && Number.isFinite(latestStarted)
      && latestStarted > now - 86400000;
    const hasActiveOverride = overrides.some((override) => override && typeof override === 'object' && override.active === true);
    const itemKey = hasActiveOverride ? groupedItemKey + '|report:' + reportId : groupedItemKey;
    preparedContexts.push({ context, reportId, reportedName, canonicalReportedName, canonicalCurrentClub, canonicalFormerClub, canonicalDestinationClub, destinationEligible, providerId, aliases, overrides, latestStatus, currentClubKey, formerClubKey, destinationClubKey, reportedNameKey, itemKey, forceResolverRetry, hardBackoff, ambiguityCooldown, hasActiveOverride });
  }
}
const enrichmentPriority = ({ context }) => {
  if (context.classification === 'official_confirmed') return 0;
  const username = String(context.source_username ?? '').toLowerCase();
  const displayName = String(context.source_name ?? '').trim().toLowerCase();
  if (username === 'fabrizioromano' || username === 'david_ornstein' || displayName === 'fabrizio romano' || displayName === 'david ornstein') return 1;
  if (context.classification === 'rumor' && context.is_huge_rumor === true) return 2;
  if (context.classification === 'rumor' && Number(context.fee_amount) >= 70000000 && ['EUR', 'GBP'].includes(String(context.fee_currency ?? '').toUpperCase())) return 3;
  return 4;
};
const classificationWeight = { contract_renewal: 6, rejected_failed: 5, loan: 4, official_confirmed: 3, advanced_negotiations: 2, rumor: 1 };
preparedContexts.sort((left, right) => {
  const eligible = ({ context }) => context.is_digest_worthy === true && namedContext(context.current_club_name) && namedContext(context.destination_club_name);
  return Number(right.context.is_current_request !== false) - Number(left.context.is_current_request !== false)
    || Number(eligible(right)) - Number(eligible(left))
    || enrichmentPriority(left) - enrichmentPriority(right)
    || Number(left.context.source_priority_rank ?? 100) - Number(right.context.source_priority_rank ?? 100)
    || Number(right.context.source_reliability_score ?? 0) - Number(left.context.source_reliability_score ?? 0)
    || (classificationWeight[right.context.classification] ?? 0) - (classificationWeight[left.context.classification] ?? 0)
    || Number(right.context.confidence ?? 0) - Number(left.context.confidence ?? 0)
    || Number(left.reportId) - Number(right.reportId);
});
const hardBackoffGroups = new Set(preparedContexts.filter(({ hardBackoff }) => hardBackoff).map(({ itemKey }) => itemKey));
const ambiguityCooldownGroups = new Set(preparedContexts.filter(({ ambiguityCooldown }) => ambiguityCooldown).map(({ itemKey }) => itemKey));
const overrideGroups = new Set(preparedContexts.filter(({ hasActiveOverride }) => hasActiveOverride).map(({ itemKey }) => itemKey));
const forceRetryGroups = new Set(preparedContexts.filter(({ forceResolverRetry }) => forceResolverRetry).map(({ itemKey }) => itemKey));
const groups = new Map();
for (const prepared of preparedContexts) {
    const { context, reportId, reportedName, canonicalReportedName, canonicalCurrentClub, canonicalFormerClub, canonicalDestinationClub, destinationEligible, providerId, aliases, overrides, latestStatus, currentClubKey, formerClubKey, destinationClubKey, reportedNameKey, itemKey } = prepared;
    if (!forceRetryGroups.has(itemKey) && (hardBackoffGroups.has(itemKey) || (ambiguityCooldownGroups.has(itemKey) && !overrideGroups.has(itemKey)))) continue;
    if (providerId && fresh(context.profile_fresh_until)
      && (fresh(context.statistics_fresh_until)
        || context.profile_current_provider_team_id === null
        || latestStatus === 'unattached')) continue;
    const existing = groups.get(itemKey);
    if (existing) {
      existing.report_ids.push(reportId);
      for (const alias of aliases) if (typeof alias === 'string' && alias.trim() && !existing.aliases.includes(alias.trim())) existing.aliases.push(alias.trim());
      if (canonicalReportedName !== reportedName && !existing.aliases.includes(reportedName)) existing.aliases.push(reportedName);
      for (const override of overrides) if (!existing.identity_overrides.some((candidate) => JSON.stringify(candidate) === JSON.stringify(override))) existing.identity_overrides.push(override);
      continue;
    }
    groups.set(itemKey, {
      item_key: itemKey,
      reported_name: canonicalReportedName,
      known_provider_player_id: providerId || null,
      current_club_name: typeof canonicalCurrentClub === 'string' ? canonicalCurrentClub : null,
      current_club_aliases: entityAliases.club_variants[normalizeAlias(canonicalCurrentClub)] ?? [],
      former_club_name: typeof canonicalFormerClub === 'string' ? canonicalFormerClub : null,
      former_club_aliases: entityAliases.club_variants[normalizeAlias(canonicalFormerClub)] ?? [],
      destination_club_name: destinationEligible && typeof canonicalDestinationClub === 'string' ? canonicalDestinationClub : null,
      destination_club_aliases: destinationEligible ? entityAliases.club_variants[normalizeAlias(canonicalDestinationClub)] ?? [] : [],
      report_ids: [reportId],
      aliases: [...new Set([...aliases, canonicalReportedName !== reportedName ? reportedName : null].filter((alias) => typeof alias === 'string' && alias.trim()).map((alias) => alias.trim()))],
      identity_overrides: overrides,
      team_mapping: context.team_mapping_fresh === true ? parseValue(context.team_mapping, null) : null,
      season_mapping: context.season_mapping_fresh === true ? parseValue(context.season_mapping, null) : null,
      request_context: { reported_name_key: reportedNameKey, current_club_key: currentClubKey, former_club_key: formerClubKey, destination_club_key: destinationClubKey },
    });
}
const players = [...groups.values()].slice(0, 25);
const request = players.length ? {
  request_id: 'sofascore:' + prepared.workflow_run_id,
  deadline_ms: 75000,
  players,
} : null;
return [{ json: {
  mode,
  workflow_run_id: prepared.workflow_run_id,
  refresh_required: request !== null,
  request,
} }];`;
}

function normalizeEnrichmentCode() {
  return `
${runtimeHelpers()}
const requestItem = $('Build soccerdata enrichment request').first().json;
const request = requestItem.request;
const players = Array.isArray(request?.players) ? request.players : [];
const failure = (player, code) => ({
  item_key: player.item_key,
  report_ids: player.report_ids,
  request_context: player.request_context ?? {},
  status: 'schema_failure',
  resolver_version: 'identity-v7',
  retryable: true,
  provider_calls: 0,
  cache_hits: 0,
  identity: null,
  profile: null,
  statistics: null,
  candidates: [],
  error: { code },
});
const failAll = (code) => ({ request_id: request?.request_id ?? '', items: players.map((player) => failure(player, code)) });
const normalizeEnrichmentCandidates = (candidates) => {
  if (!Array.isArray(candidates)) return [];
  const normalized = [];
  for (const candidate of candidates) {
    const providerPlayerId = typeof candidate?.provider_player_id === 'string' ? candidate.provider_player_id : '';
    const canonicalName = typeof candidate?.canonical_name === 'string' ? candidate.canonical_name.trim() : '';
    if (!/^\\d+$/.test(providerPlayerId) || !canonicalName || typeof candidate?.score !== 'number' || !Number.isFinite(candidate.score) || candidate.score < 0 || candidate.score > 100) continue;
    normalized.push({ provider_player_id: providerPlayerId, canonical_name: canonicalName, score: candidate.score });
    if (normalized.length === 5) break;
  }
  return normalized;
};
const allowed = new Set(['cache_hit', 'fresh', 'partial', 'unresolved', 'ambiguous', 'deferred', 'provider_failure', 'rate_limited', 'timeout', 'schema_failure', 'unsupported_competition', 'missing_season', 'club_conflict', 'unattached']);
let normalized;
const statusCode = Number($json.statusCode ?? (typeof $json.status === 'number' ? $json.status : 200));
if (!Number.isFinite(statusCode) || statusCode < 200 || statusCode > 299 || $json.error) {
  normalized = failAll('enrichment_service_failed');
} else {
  let body = $json.body ?? $json;
  try { if (typeof body === 'string') body = JSON.parse(body); } catch { body = null; }
  if (!body || typeof body !== 'object' || body.request_id !== request?.request_id || !Array.isArray(body.items)) {
    normalized = failAll(body === null ? 'enrichment_response_not_json' : 'service_contract_invalid');
  } else {
    const byKey = new Map();
    let invalid = false;
    for (const item of body.items) {
      if (!item || typeof item !== 'object' || typeof item.item_key !== 'string' || byKey.has(item.item_key)) invalid = true;
      else byKey.set(item.item_key, item);
    }
    if (invalid) {
      normalized = failAll('service_contract_invalid');
    } else {
      normalized = {
        request_id: request.request_id,
        items: players.map((player) => {
          const item = byKey.get(player.item_key);
          if (!item || !allowed.has(item.status) || typeof item.resolver_version !== 'string' || !item.resolver_version) return failure(player, 'service_contract_invalid');
          const identity = item.identity;
          const providerId = String(identity?.provider_player_id ?? '');
          const identityForbidden = ['unresolved', 'ambiguous', 'deferred', 'provider_failure', 'rate_limited', 'timeout', 'schema_failure'].includes(item.status);
          if (identityForbidden && identity !== null) return failure(player, 'service_contract_invalid');
          if (identity !== null && (!identity || identity.provider !== 'sofascore' || !/^\\d+$/.test(providerId) || typeof identity.score !== 'number' || !Number.isFinite(identity.score) || identity.score < 0 || identity.score > 100 || typeof identity.margin !== 'number' || !Number.isFinite(identity.margin) || identity.margin < 0 || identity.margin > 100 || identity.margin > identity.score)) return failure(player, 'service_contract_invalid');
          if (['fresh', 'cache_hit', 'partial'].includes(item.status) && (!identity || !item.profile || typeof item.profile !== 'object')) return failure(player, 'service_contract_invalid');
          if (['fresh', 'cache_hit'].includes(item.status) && (!item.statistics || typeof item.statistics !== 'object')) return failure(player, 'service_contract_invalid');
          if (item.profile && (!Number.isFinite(Date.parse(String(item.profile.retrieved_at ?? ''))) || (item.profile.current_club !== null && (typeof item.profile.current_club !== 'object' || !/^\\d+$/.test(String(item.profile.current_club.provider_team_id ?? '')) || typeof item.profile.current_club.name !== 'string' || !item.profile.current_club.name.trim())) || (item.profile.market_value_currency !== null && item.profile.market_value_currency !== undefined && !/^[A-Z]{3}$/.test(String(item.profile.market_value_currency))))) return failure(player, 'service_contract_invalid');
          if (item.statistics && (!/^\\d+$/.test(String(item.statistics.provider_unique_tournament_id ?? '')) || !/^\\d+$/.test(String(item.statistics.provider_season_id ?? '')) || !['active', 'latest_completed'].includes(item.statistics.season_state) || item.statistics.scope !== 'selected_domestic_league_all_clubs' || !Number.isFinite(Date.parse(String(item.statistics.retrieved_at ?? ''))))) return failure(player, 'service_contract_invalid');
          const rawProfile = item.provenance?.raw_payloads?.profile && typeof item.provenance.raw_payloads.profile === 'object' ? item.provenance.raw_payloads.profile : {};
          const rawStatistics = item.provenance?.raw_payloads?.statistics && typeof item.provenance.raw_payloads.statistics === 'object' ? item.provenance.raw_payloads.statistics : {};
          return {
            item_key: player.item_key,
            report_ids: player.report_ids,
            request_context: player.request_context ?? {},
            status: item.status,
            resolver_version: item.resolver_version,
            retryable: item.error?.retryable === true || (Array.isArray(item.warnings) && item.warnings.some((warning) => warning?.retryable === true)),
            provider_calls: Number.isInteger(item.provider_calls) && item.provider_calls >= 0 ? item.provider_calls : 0,
            cache_hits: Number(item.provenance?.profile_cache === 'hit') + Number(item.provenance?.statistics_cache === 'hit'),
            identity: identity ? {
              provider: 'sofascore',
              provider_player_id: providerId,
              stable_source_identifier: String(identity.stable_source_identifier ?? 'sofascore:player:' + providerId),
              canonical_name: typeof item.profile?.canonical_name === 'string' ? item.profile.canonical_name : player.reported_name,
              score: Number.isFinite(identity.score) ? identity.score : null,
              margin: Number.isFinite(identity.margin) ? identity.margin : null,
              resolver_version: typeof identity.resolver_version === 'string' && identity.resolver_version ? identity.resolver_version : item.resolver_version,
            } : null,
            profile: item.profile && typeof item.profile === 'object' ? {
              ...item.profile,
              content_sha256: sha256(item.profile),
              raw_sha256: sha256(rawProfile),
              raw_cache_key: providerId ? 'profile-' + providerId : null,
              raw_payload: rawProfile,
            } : null,
            statistics: item.statistics && typeof item.statistics === 'object' ? {
              ...item.statistics,
              content_sha256: sha256(item.statistics),
              raw_sha256: sha256(rawStatistics),
              raw_cache_key: providerId ? 'statistics-' + providerId + '-' + item.statistics.provider_unique_tournament_id + '-' + item.statistics.provider_season_id : null,
              raw_payload: rawStatistics,
            } : null,
            candidates: normalizeEnrichmentCandidates(item.candidates),
            warning_codes: Array.isArray(item.warnings) ? item.warnings.map((warning) => String(warning?.code ?? '')).filter(Boolean) : [],
            error: item.error && typeof item.error === 'object' ? { code: String(item.error.code ?? 'enrichment_failed').slice(0, 100) } : null,
          };
        }),
      };
    }
  }
}
return [{ json: {
  params: [JSON.stringify(normalized), requestItem.workflow_run_id],
  normalized,
} }];`;
}

function digestCode() {
  return `
${entityAliasHelpers()}
const precedence = { contract_renewal: 6, rejected_failed: 5, loan: 4, official_confirmed: 3, advanced_negotiations: 2, rumor: 1 };
const truncate = (value, maximum) => {
  const text = String(value ?? '');
  if (text.length <= maximum) return text;
  const segments = typeof Intl.Segmenter === 'function'
    ? [...new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(text)].map(({ segment }) => segment)
    : [...text];
  let result = '';
  for (const segment of segments) {
    if (result.length + segment.length + 1 > maximum) break;
    result += segment;
  }
  return result + '…';
};
const amount = (value, currency) => value === null || value === undefined ? null : (Number(value).toLocaleString('en-US') + ' ' + (currency ?? '')).trim();
const finiteNumber = (value) => {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
};
const namedEnrichmentValue = (value) => {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text && !/^(unknown|n\\/?a|not[ _-]?reported)$/i.test(text) ? text : null;
};
const staleLabel = (snapshot, now, maximumAgeMs) => {
  if (snapshot?.stale !== true) return '';
  const retrievedAt = Date.parse(String(snapshot.retrieved_at ?? ''));
  const ageMs = now - retrievedAt;
  if (!Number.isFinite(retrievedAt) || ageMs < 0 || ageMs > maximumAgeMs) return null;
  if (ageMs < 60 * 60 * 1000) return 'stale <1h';
  const hours = Math.floor(ageMs / (60 * 60 * 1000));
  return hours >= 48 ? 'stale ' + Math.floor(hours / 24) + 'd' : 'stale ' + hours + 'h';
};
const compactValue = (value, currency) => {
  const marketValue = finiteNumber(value);
  const code = String(currency ?? '').trim().toUpperCase();
  if (marketValue === null || marketValue < 0 || !/^[A-Z]{3}$/.test(code)) return null;
  const units = marketValue >= 1000000
    ? Number((marketValue / 1000000).toFixed(1)) + 'm'
    : (marketValue >= 1000 ? Number((marketValue / 1000).toFixed(1)) + 'k' : String(marketValue));
  const symbols = { EUR: '€', GBP: '£', USD: '$' };
  return symbols[code] ? symbols[code] + units : units + ' ' + code;
};
const integerStatistic = (value, label) => {
  const number = finiteNumber(value);
  return number === null ? null : Math.trunc(number).toLocaleString('en-US') + ' ' + label;
};
const decimalStatistic = (value, label) => {
  const number = finiteNumber(value);
  return number === null ? null : number.toFixed(2) + ' ' + label;
};
const enrichmentGroups = (enrichment, now) => {
  if (!enrichment || typeof enrichment !== 'object' || Array.isArray(enrichment)) return [];
  const profile = enrichment.profile && typeof enrichment.profile === 'object' && !Array.isArray(enrichment.profile) ? enrichment.profile : null;
  const statistics = enrichment.statistics && typeof enrichment.statistics === 'object' && !Array.isArray(enrichment.statistics) ? enrichment.statistics : null;
  const profileClub = namedEnrichmentValue(profile?.current_club_name);
  const profileStale = profile ? staleLabel(profile, now, profileClub ? 72 * 60 * 60 * 1000 : 7 * 24 * 60 * 60 * 1000) : null;
  const statisticsStale = statistics ? staleLabel(statistics, now, 72 * 60 * 60 * 1000) : null;
  const competition = namedEnrichmentValue(statistics?.competition_name);
  const season = namedEnrichmentValue(statistics?.season_label);
  const scope = statistics?.scope === 'selected_domestic_league_all_clubs' ? 'all clubs' : null;
  const statisticsValid = Boolean(statistics && statisticsStale !== null && competition && season && scope);
  const primaryStatistics = statisticsValid ? [
    integerStatistic(statistics.appearances, 'app'),
    integerStatistic(statistics.minutes_played, 'min'),
    integerStatistic(statistics.goals, 'G'),
    integerStatistic(statistics.assists, 'A'),
  ].filter(Boolean) : [];
  const marketValue = profile ? compactValue(profile.market_value, profile.market_value_currency) : null;
  const profileParts = profile && profileStale !== null ? [
    profileClub,
    namedEnrichmentValue(profile.nationality),
    finiteNumber(profile.age) === null ? null : String(Math.trunc(finiteNumber(profile.age))),
    namedEnrichmentValue(profile.primary_position),
    marketValue ? 'Sofascore value ' + marketValue : null,
  ].filter(Boolean) : [];
  const profileLine = profileParts.length ? 'Profile' + (profileStale ? ' · ' + profileStale : '') + ': ' + profileParts.join(' · ') : null;
  const advancedStatistics = statisticsValid ? [
    integerStatistic(statistics.starts, 'starts'),
    finiteNumber(statistics.minutes_per_appearance) === null ? null : Number(finiteNumber(statistics.minutes_per_appearance).toFixed(1)) + ' min/app',
    decimalStatistic(statistics.expected_goals, 'xG'),
    decimalStatistic(statistics.expected_assists, 'xA'),
    decimalStatistic(statistics.average_rating, 'rating'),
  ].filter(Boolean) : [];
  const profileDetails = profile && profileStale !== null ? [
    namedEnrichmentValue(profile.date_of_birth) ? 'Born ' + profile.date_of_birth.trim() : null,
    finiteNumber(profile.height_cm) === null ? null : Math.trunc(finiteNumber(profile.height_cm)) + ' cm',
    namedEnrichmentValue(profile.preferred_foot) ? profile.preferred_foot.trim() + ' foot' : null,
  ].filter(Boolean) : [];
  const lowerPriorityStatistics = statisticsValid ? [
    integerStatistic(statistics.yellow_cards, 'yellow'),
    integerStatistic(statistics.red_cards, 'red'),
    ...(profile?.primary_position === 'Goalkeeper' ? [
      integerStatistic(statistics.goalkeeper_clean_sheets, 'clean sheets'),
      integerStatistic(statistics.goalkeeper_saves, 'saves'),
    ] : []),
  ].filter(Boolean) : [];
  const statisticsValues = [...primaryStatistics, ...advancedStatistics];
  const statisticsContextLine = statisticsValid && (statisticsValues.length || lowerPriorityStatistics.length || statisticsStale)
    ? (statisticsValues.length || statisticsStale
      ? competition + ' ' + season + ' - ' + scope + ': ' + [...statisticsValues, statisticsStale || null].filter(Boolean).join(' · ')
      : competition + ' ' + season + ' - ' + scope)
    : null;
  return [
    { priority: 1, displayOrder: 1, line: profileLine },
    { priority: 2, displayOrder: 2, line: statisticsContextLine },
    { priority: 3, displayOrder: 3, line: profileDetails.length ? 'Details: ' + profileDetails.join(' · ') : null },
    { priority: 4, displayOrder: 4, line: lowerPriorityStatistics.length ? 'Other: ' + lowerPriorityStatistics.join(' · ') : null },
  ];
};
const hasNamedClub = (value) => typeof value === 'string' && value.trim().length > 0 && !/^(not[ _-]?reported|unknown|n\\/?a)$/i.test(value.trim());
const equivalentClub = (left, right) => {
  if (!hasNamedClub(left) || !hasNamedClub(right)) return false;
  const parts = (value) => normalizeAlias(entityAliases.clubs[normalizeAlias(value)] ?? value).split(' ').filter(Boolean);
  const stripSuffix = (values) => ['afc', 'cf', 'cp', 'fc', 'sc'].includes(values.at(-1)) ? values.slice(0, -1) : values;
  const leftParts = stripSuffix(parts(left));
  const rightParts = stripSuffix(parts(right));
  return leftParts.length > 0 && leftParts.join(' ') === rightParts.join(' ');
};
const withPresentationCurrentClub = (report) => {
  if (hasNamedClub(report.current_club_name) || report.pending_idempotency_key) return report;
  const profile = report.enrichment?.profile;
  const profileClub = namedEnrichmentValue(profile?.current_club_name);
  const allowedClassification = ['rumor', 'advanced_negotiations', 'rejected_failed', 'contract_renewal'].includes(report.classification);
  if (!profileClub || profile?.stale !== false || !allowedClassification || report.move_type === 'loan' || equivalentClub(profileClub, report.destination_club_name)) return report;
  return { ...report, current_club_name: profileClub };
};
const isDigestEligible = (report) => report.is_digest_worthy === true && hasNamedClub(report.current_club_name) && hasNamedClub(report.destination_club_name);
const digestHistoryKey = (report) => [report.player_name, report.destination_club_name].map(normalizeAlias).join('|');
const configuredSiblingPair = (left, right) => {
  const leftName = normalizeAlias(left.player_name);
  const rightName = normalizeAlias(right.player_name);
  if (!leftName || leftName === rightName) return false;
  return entityAliases.sibling_groups.some((group) => {
    const members = group.map(normalizeAlias);
    return members.includes(leftName) && members.includes(rightName);
  });
};
const digestPlayerConflict = (left, right) => {
  const leftName = normalizeAlias(left.player_name);
  const rightName = normalizeAlias(right.player_name);
  if (leftName === rightName) return true;
  if (configuredSiblingPair(left, right)) return false;
  const leftTokens = leftName.split(' ').filter(Boolean);
  const rightTokens = rightName.split(' ').filter(Boolean);
  const surname = leftTokens.at(-1);
  if (!surname || surname !== rightTokens.at(-1)) return false;
  if (leftTokens.length === 1 || rightTokens.length === 1) return true;
  if (!entityAliases.common_surnames.includes(surname)) return true;
  const leftGiven = new Set(leftTokens.slice(0, -1).filter((token) => token.length > 1));
  const rightGiven = new Set(rightTokens.slice(0, -1).filter((token) => token.length > 1));
  return leftGiven.size === 0 || rightGiven.size === 0 || [...leftGiven].some((token) => rightGiven.has(token));
};
const digestUpdateFields = ['classification', 'move_type', 'fee_amount', 'fee_currency', 'add_ons_amount', 'add_ons_currency', 'release_clause_amount', 'release_clause_currency', 'contract_length_months', 'contract_expires_on', 'loan_ends_on', 'has_option_to_buy', 'has_obligation_to_buy', 'sell_on_percentage', 'medical_status', 'agreement_status', 'confidence'];
const digestMaterialKey = (report) => JSON.stringify(Object.fromEntries(digestUpdateFields.map((field) => [field, report[field] ?? null])));
const sameDigestStory = (left, right) => digestHistoryKey(left) === digestHistoryKey(right);
const digestPriority = (report) => {
  if (report.classification === 'official_confirmed') return 0;
  const username = String(report.preferred_source.username ?? '').toLowerCase();
  const displayName = String(report.preferred_source.display_name ?? '').trim().toLowerCase();
  if (username === 'fabrizioromano' || username === 'david_ornstein' || displayName === 'fabrizio romano' || displayName === 'david ornstein') return 1;
  if (report.classification === 'rumor' && report.is_huge_rumor === true) return 2;
  if (report.classification === 'rumor' && Number(report.fee_amount) >= 70000000 && ['EUR', 'GBP'].includes(String(report.fee_currency ?? '').toUpperCase())) return 3;
  return 4;
};
const rows = $input.all().map((item) => ({ row_type: item.json.row_type, payload: typeof item.json.payload === 'string' ? JSON.parse(item.json.payload) : item.json.payload }));
const sentHistory = rows.find((row) => row.row_type === 'sent_history')?.payload ?? [];
const reports = rows.filter((row) => row.row_type === 'candidate').map((row) => {
  const item = row.payload ?? {};
  const snapshot = typeof item.snapshot === 'string' ? JSON.parse(item.snapshot) : item.snapshot;
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot) || typeof snapshot.classification !== 'string') return null;
  return withPresentationCurrentClub(canonicalizeReport({ ...snapshot, enrichment: item.enrichment ?? null, revision_id: item.revision_id, post_url: item.post_url, pending_idempotency_key: item.pending_idempotency_key, pending_window_started_at: item.pending_window_started_at, pending_window_ended_at: item.pending_window_ended_at, pending_request_payload: item.pending_request_payload, sent_history: sentHistory, preferred_source: { priority_rank: Number(item.priority_rank), reliability_score: Number(item.reliability_score), username: item.source_username, display_name: item.source_name } }));
}).filter(Boolean).sort((a, b) => (digestPriority(a) - digestPriority(b)) || (a.preferred_source.priority_rank - b.preferred_source.priority_rank) || (b.preferred_source.reliability_score - a.preferred_source.reliability_score) || (precedence[b.classification] - precedence[a.classification]) || (b.confidence - a.confidence));
const pending = reports.find((report) => report.pending_idempotency_key);
const isNewDigestUpdate = (report) => {
  const sent = (Array.isArray(report.sent_history) ? report.sent_history : []).filter((entry) => entry?.snapshot && entry?.sent_at).map((entry) => ({ ...entry, snapshot: canonicalizeReport(entry.snapshot) })).filter((entry) => sameDigestStory(report, entry.snapshot));
  const confirmedWithinCooldown = sent.some((entry) => entry.snapshot.classification === 'official_confirmed' && Date.now() - Date.parse(entry.sent_at) < 7 * 24 * 60 * 60 * 1000);
  if (report.classification !== 'rejected_failed' && confirmedWithinCooldown) return false;
  return !sent.some((entry) => digestMaterialKey(entry.snapshot) === digestMaterialKey(report));
};
const candidateReports = pending ? reports.filter((report) => report.pending_idempotency_key === pending.pending_idempotency_key) : reports.filter((report) => isDigestEligible(report) && isNewDigestUpdate(report));
const seenRevisionIds = new Set();
const distinctCandidateReports = [];
for (const report of candidateReports) {
  const revisionId = String(report.revision_id ?? '');
  if (!revisionId || seenRevisionIds.has(revisionId)) continue;
  if (distinctCandidateReports.some((selectedReport) => digestPlayerConflict(selectedReport, report))) continue;
  seenRevisionIds.add(revisionId);
  distinctCandidateReports.push(report);
}
const selected = [...distinctCandidateReports.slice(0, 15), ...distinctCandidateReports.slice(15).filter((report) => digestPriority(report) < 2).slice(0, 3)];
const now = new Date();
const title = 'Football transfer digest';
const footerText = (count) => String(count) + ' new material report' + (count === 1 ? '' : 's');
const fields = [];
for (const report of selected) {
  if (fields.length >= 25) break;
  const name = truncate(String(fields.length + 1) + '. ' + report.player_name, 256);
  const sourceLine = report.post_url ? '[' + report.preferred_source.display_name + '](' + report.post_url + ')' : report.preferred_source.display_name;
  const lines = [
    report.current_club_name + ' → ' + report.destination_club_name,
    'Classification: ' + report.classification.replaceAll('_', ' '),
    report.move_type && report.move_type !== 'unknown' ? 'Move: ' + report.move_type : null,
    amount(report.fee_amount, report.fee_currency) ? 'Fee: ' + amount(report.fee_amount, report.fee_currency) : null,
    amount(report.add_ons_amount, report.add_ons_currency) ? 'Add-ons: ' + amount(report.add_ons_amount, report.add_ons_currency) : null,
    amount(report.release_clause_amount, report.release_clause_currency) ? 'Release clause: ' + amount(report.release_clause_amount, report.release_clause_currency) : null,
    report.contract_length_months !== null && report.contract_length_months !== undefined ? 'Contract length: ' + report.contract_length_months + ' months' : null,
    report.contract_expires_on ? 'Contract expires: ' + report.contract_expires_on : null,
    report.loan_ends_on ? 'Loan ends: ' + report.loan_ends_on : null,
    report.has_option_to_buy !== null && report.has_option_to_buy !== undefined ? 'Option to buy: ' + (report.has_option_to_buy ? 'Yes' : 'No') : null,
    report.has_obligation_to_buy !== null && report.has_obligation_to_buy !== undefined ? 'Obligation to buy: ' + (report.has_obligation_to_buy ? 'Yes' : 'No') : null,
    report.sell_on_percentage !== null && report.sell_on_percentage !== undefined ? 'Sell-on: ' + report.sell_on_percentage + '%' : null,
    report.medical_status && !['not_reported', 'unknown'].includes(report.medical_status) ? 'Medical: ' + report.medical_status : null,
    report.agreement_status && !['not_reported', 'unknown'].includes(report.agreement_status) ? 'Agreement: ' + report.agreement_status : null,
    'Confidence: ' + Math.round(report.confidence * 100) + '%',
    sourceLine,
  ].filter(Boolean);
  const source = lines.at(-1);
  const transferLines = lines.slice(0, -1);
  const enrichmentHeading = '**Player profile & statistics**';
  const accepted = [];
  for (const group of enrichmentGroups(report.enrichment, now.valueOf())) {
    if (!group.line) continue;
    const nextAccepted = [...accepted, group];
    const enrichmentLines = nextAccepted.sort((left, right) => left.displayOrder - right.displayOrder).map(({ line }) => line);
    const candidate = [...transferLines, enrichmentHeading, ...enrichmentLines, source].join('\\n');
    if (candidate.length > 1024) continue;
    accepted.push(group);
  }
  const enrichmentLines = accepted.sort((left, right) => left.displayOrder - right.displayOrder).map(({ line }) => line);
  const value = accepted.length
    ? [...transferLines, enrichmentHeading, ...enrichmentLines, source].join('\\n')
    : lines.join('\\n');
  const currentCharacters = title.length + footerText(fields.length).length + fields.reduce((total, field) => total + field.name.length + field.value.length, 0);
  const candidateCharacters = currentCharacters - footerText(fields.length).length + footerText(fields.length + 1).length + name.length + value.length;
  if (value.length > 1024 || candidateCharacters > 6000) continue;
  fields.push({ name, value, inline: false, revision_id: report.revision_id });
}
const start = new Date(now); start.setMinutes(0, 0, 0); start.setHours(Math.floor(start.getHours() / 6) * 6);
const end = new Date(start.valueOf() + 6 * 60 * 60 * 1000);
const payload = { allowed_mentions: { parse: [] }, embeds: [{ title, color: 1940464, fields: fields.map(({ name, value, inline }) => ({ name, value, inline })), footer: { text: footerText(fields.length) } }] };
let discordPayload = payload;
if (pending) {
  try {
    discordPayload = typeof pending.pending_request_payload === 'string'
      ? JSON.parse(pending.pending_request_payload)
      : pending.pending_request_payload;
  } catch {
    return [];
  }
  if (!discordPayload || typeof discordPayload !== 'object' || Array.isArray(discordPayload)) return [];
}
return fields.length ? [{ json: { params: [JSON.stringify({ idempotency_key: pending?.pending_idempotency_key ?? 'transfer-digest|' + start.toISOString(), window_started_at: pending?.pending_window_started_at ?? start.toISOString(), window_ended_at: pending?.pending_window_ended_at ?? end.toISOString(), revision_ids: fields.map((field) => field.revision_id), discord_payload: discordPayload })] } }] : [];`;
}
function mainWorkflow({ registry, prompt, schema }) {
  const registryJson = JSON.stringify(registry);
  const schemaJson = JSON.stringify(schema);
  const nodes = [
    node('Every six hours', 'n8n-nodes-base.scheduleTrigger', [-1120, -140], {
      rule: { interval: [{ field: 'cronExpression', expression: '0 0,6,12,18 * * *' }] },
    }, { typeVersion: 1.2 }),
    node('Manual run', 'n8n-nodes-base.manualTrigger', [-1120, 40], {}, { typeVersion: 1 }),
    node('Manual sample run', 'n8n-nodes-base.manualTrigger', [-1120, 220], {}, { typeVersion: 1 }),
    postgresNode('Recover interrupted deliveries', [-900, -40], `UPDATE digest_deliveries SET status = 'unknown' WHERE status = 'sending' RETURNING id::text AS digest_delivery_id;`),
    postgresNode('Recover interrupted sample deliveries', [-900, 220], `UPDATE digest_deliveries SET status = 'unknown' WHERE status = 'sending' RETURNING id::text AS digest_delivery_id;`),
    codeNode('Create run context', [-700, -40], `
const now = new Date();
const start = new Date(now); start.setMinutes(0, 0, 0); start.setHours(Math.floor(start.getHours() / 6) * 6);
const collectionStartedAt = now.toISOString();
const collectionCutoffAt = new Date(now.valueOf() - 6 * 60 * 60 * 1000).toISOString();
return [{ json: { params: [String($execution.id), start.toISOString(), JSON.stringify({ trigger: $execution.mode, started_at: collectionStartedAt, collection_cutoff_at: collectionCutoffAt })], logical_run_key: start.toISOString(), collection_started_at: collectionStartedAt, collection_cutoff_at: collectionCutoffAt } }];`),
    codeNode('Create sample run context', [-700, 220], `
const now = new Date();
const start = new Date(now); start.setMinutes(0, 0, 0); start.setHours(Math.floor(start.getHours() / 6) * 6);
const collectionStartedAt = now.toISOString();
const collectionCutoffAt = new Date(now.valueOf() - 6 * 60 * 60 * 1000).toISOString();
return [{ json: { params: [String($execution.id), start.toISOString(), JSON.stringify({ trigger: 'manual_sample', started_at: collectionStartedAt, collection_cutoff_at: collectionCutoffAt, sample: true })], logical_run_key: start.toISOString(), collection_started_at: collectionStartedAt, collection_cutoff_at: collectionCutoffAt } }];`),
    postgresNode('Register workflow run', [-500, -40], runRegistrationSql()),
    postgresNode('Register sample workflow run', [-500, 220], runRegistrationSql()),
    codeNode('Load generated sources', [-300, -40], `
const sources = ${registryJson};
return sources.map((source) => ({ json: { source, params: [source.platform, source.external_account_id, source.username, source.display_name, source.account_type, source.is_official, source.priority_rank, source.reliability_score] } }));`),
    postgresNode('Upsert source accounts', [-100, -40], sourceUpsertSql()),
    codeNode('Load sample source', [-300, 220], `
const source = { platform: 'x', external_account_id: '242077026', username: 'AdamCrafton_', display_name: 'Adam Crafton', account_type: 'individual', is_official: false, priority_rank: 4, reliability_score: 0.70 };
return [{ json: { source, params: [source.platform, source.external_account_id, source.username, source.display_name, source.account_type, source.is_official, source.priority_rank, source.reliability_score] } }];`),
    postgresNode('Upsert sample source account', [-100, 220], sourceUpsertSql()),
    codeNode('Select X collector', [100, -40], `
const collector = String($env.X_COLLECTOR ?? '').trim().toLowerCase();
if (!['rapidapi', 'twscrape'].includes(collector)) throw new Error('X_COLLECTOR must be explicitly set to rapidapi or twscrape');
return $input.all().map((item) => ({ json: { ...item.json, collector } }));`),
    node('Use twscrape collector', 'n8n-nodes-base.if', [280, -40], { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: '={{ $json.collector }}', rightValue: 'twscrape', operator: { type: 'string', operation: 'equals' } }], combinator: 'and' } }, { typeVersion: 2.2 }),
    codeNode('Build twscrape collect request', [440, -160], `
const sources = $input.all().map((item) => ({
  source_id: String(item.json.source_account_id),
  username: String(item.json.username),
  x_user_id: String(item.json.external_account_id),
  external_account_id: String(item.json.external_account_id),
  display_name: item.json.display_name,
  priority_rank: item.json.priority_rank,
  reliability_score: item.json.reliability_score,
  is_official: item.json.is_official,
}));
return [{ json: { sources, body: { sources: sources.map(({ source_id, username, x_user_id }) => ({ source_id, username, x_user_id })), limit: 20 } } }];`),
    httpNode('Collect 20 X posts via twscrape', [660, -160], {
      method: 'POST', url: '={{ ($env.TWSCRAPE_BASE_URL || "http://twscrape:8080") + "/collect" }}', sendBody: true,
      contentType: 'json', specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.body) }}',
    }, { continueOnFail: true, requestOptions: { timeout: 310000 } }),
    codeNode('Normalize twscrape posts', [880, -160], twscrapeParserCode()),
    codeNode('Build RapidAPI request', [440, -40], `
if (!String($env.RAPIDAPI_KEY ?? '').trim()) throw new Error('RAPIDAPI_KEY is required when X_COLLECTOR=rapidapi');
return $input.all().map((item) => ({ json: { source: item.json, requestPath: '/user/' + item.json.external_account_id + '/tweets?count=20&username=' + encodeURIComponent(item.json.username), attempt: 1 } }));`),
    httpNode('Collect 20 X posts', [660, -40], {
      method: 'GET', url: '={{ ($env.RAPIDAPI_BASE_URL || "https://twittr-v2-fastest-twitter-x-api-150k-requests-for-15.p.rapidapi.com") + $json.requestPath }}', sendHeaders: true,
      headerParameters: { parameters: [
        { name: 'Content-Type', value: 'application/json' },
        { name: 'x-rapidapi-host', value: 'twittr-v2-fastest-twitter-x-api-150k-requests-for-15.p.rapidapi.com' },
        { name: 'x-rapidapi-key', value: '={{ $env.RAPIDAPI_KEY }}' },
      ] },
    }, { continueOnFail: true, retryOnFail: true, maxTries: 5, waitBetweenTries: 1000 }),
    codeNode('Load sample collected X posts', [320, 220], `
const source = { platform: 'x', external_account_id: String($json.external_account_id), username: $json.username, display_name: $json.display_name, account_type: $json.account_type, is_official: $json.is_official, priority_rank: Number($json.priority_rank), reliability_score: Number($json.reliability_score) };
const createdAt = new Date().toUTCString();
const tweet = (id, text) => ({ rest_id: id, legacy: { id_str: id, full_text: text, created_at: createdAt } });
return [{ json: { source, body: { data: { entries: [
  tweet('999000000000000001', 'TEST DATA: Alex Example has agreed to join Test United from Test FC for EUR 25 million. Medical scheduled.'),
  tweet('999000000000000002', 'TEST DATA: Jamie Sample is in advanced talks to join Example City from Sample Athletic.'),
  tweet('999000000000000003', 'RT @example: TEST DATA: this pure retweet must be ignored.'),
] } } } }];`),
    codeNode('Parse RapidAPI posts', [880, -40], rapidApiParserCode()),
    postgresNode('Persist raw posts', [760, -40], rawPostUpsertSql()),
    codeNode('Build Qwen request', [980, -40], `
const prompt = ${JSON.stringify(prompt)};
const schema = ${schemaJson};
const llamaSchema = JSON.parse(JSON.stringify(schema));
delete llamaSchema.properties.reports.items.properties.player_name.minLength;
return $input.all().map((item) => ({ json: {
  raw_post_id: item.json.raw_post_id, external_post_id: item.json.external_post_id, post_url: item.json.post_url, posted_at: item.json.posted_at,
  source: { external_account_id: item.json.external_account_id, username: item.json.username, display_name: item.json.display_name, priority_rank: Number(item.json.priority_rank), reliability_score: Number(item.json.reliability_score), is_official: item.json.is_official },
  body: { model: 'qwen3.8-27b', temperature: 0, messages: [{ role: 'system', content: prompt }, { role: 'user', content: item.json.content }], response_format: { type: 'json_schema', json_schema: { name: 'football_transfer_extraction', strict: true, schema: llamaSchema } } }
} }));`),
    httpNode('Extract with Qwen', [1200, -40], {
      method: 'POST', url: '={{ $env.QWEN_CHAT_COMPLETIONS_URL || "http://llama:8080/v1/chat/completions" }}', sendBody: true,
      contentType: 'json', specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.body) }}',
    }, { continueOnFail: true, retryOnFail: true, maxTries: 3, waitBetweenTries: 1000 }),
    codeNode('Validate Qwen response', [1420, -40], qwenParseCode()),
    node('Qwen response valid', 'n8n-nodes-base.if', [1640, -40], { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: '={{ $json.valid }}', rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }], combinator: 'and' } }, { typeVersion: 2.2 }),
    postgresNode('Record Qwen validation failure', [1640, 160], qwenFailureSql()),
    node('Transfer related', 'n8n-nodes-base.if', [1860, -100], { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: '={{ !$json.ignored }}', rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }], combinator: 'and' } }, { typeVersion: 2.2 }),
    postgresNode('Mark non-transfer ignored', [1860, 80], `UPDATE raw_posts SET processing_state = 'ignored', classified_at = CURRENT_TIMESTAMP WHERE id = $1::bigint RETURNING id::text AS raw_post_id;`),
    codeNode('Merge extracted reports', [2080, -180], mergeCode()),
    postgresNode('Persist merged reports and revisions', [2300, -180], mergeReportSql()),
    codeNode('Prepare preferred source reset', [2520, -180], `
return $input.all().map((item) => {
  const reportId = String(item.json.transfer_report_id ?? '');
  const rawPostId = String(item.json.preferred_raw_post_id ?? '');
  if (!/^\\d+$/.test(reportId) || !/^\\d+$/.test(rawPostId)) throw new Error('Missing merged report preferred-source metadata');
  return { json: { params: [reportId, rawPostId] } };
});`),
    postgresNode('Clear preferred report source', [2740, -180], `
WITH cleared AS (
  UPDATE transfer_report_sources
  SET is_preferred = false
  WHERE transfer_report_id = $1::bigint AND is_preferred
  RETURNING 1
)
SELECT $1::text AS transfer_report_id, $2::text AS preferred_raw_post_id
FROM (SELECT count(*) FROM cleared) AS completed;`),
    postgresNode('Set preferred report source', [2960, -180], `
UPDATE transfer_report_sources
SET is_preferred = true
WHERE transfer_report_id = $1::bigint AND raw_post_id = $2::bigint
RETURNING $1::text AS transfer_report_id, $2::text AS preferred_raw_post_id;`, '={{ [$json.transfer_report_id, $json.preferred_raw_post_id] }}'),
    codeNode('Prepare enrichment batch query', [3180, -180], prepareEnrichmentBatchCode()),
    node('Enrichment enabled?', 'n8n-nodes-base.if', [3400, -180], { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: '={{ $json.mode !== "off" }}', rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }], combinator: 'and' } }, { typeVersion: 2.2 }),
    postgresNode('Load player enrichment contexts', [3620, -340], enrichmentContextSql(), undefined, { continueOnFail: true }),
    codeNode('Build soccerdata enrichment request', [3840, -340], buildEnrichmentRequestCode()),
    node('Refresh required?', 'n8n-nodes-base.if', [4060, -340], { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: '={{ $json.refresh_required === true }}', rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }], combinator: 'and' } }, { typeVersion: 2.2 }),
    httpNode('Enrich players via soccerdata', [4280, -500], {
      method: 'POST',
      url: '={{ ($env.SOFASCORE_ENRICHMENT_BASE_URL || "http://sofascore-enrichment:8080") + "/v1/enrich" }}',
      sendBody: true,
      contentType: 'json',
      specifyBody: 'json',
      jsonBody: '={{ JSON.stringify($json.request) }}',
    }, { continueOnFail: true, requestOptions: { timeout: 85000 } }),
    codeNode('Normalize soccerdata enrichment result', [4500, -500], normalizeEnrichmentCode()),
    postgresNode('Persist soccerdata enrichment result', [4720, -500], persistEnrichmentSql(), undefined, { continueOnFail: true }),
    codeNode('Prepare digest candidates query', [4940, -180], `
const context = $('Create run context').isExecuted ? $('Create run context').first().json : $('Create sample run context').first().json;
const selected = String($env.PLAYER_ENRICHMENT_MODE ?? 'off').trim().toLowerCase();
const mode = ['shadow', 'active'].includes(selected) ? selected : 'off';
return [{ json: { params: [context.collection_cutoff_at, context.collection_started_at, mode] } }];`),
    postgresNode('Find undelivered revisions', [5160, -180], candidatesSql()),
    codeNode('Build bounded Discord digest', [5380, -180], digestCode()),
    postgresNode('Reserve digest before delivery', [5600, -180], reserveDigestSql()),
    node('Digest reserved', 'n8n-nodes-base.if', [5820, -180], { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: '={{ !!$json.digest_delivery_id }}', rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }], combinator: 'and' } }, { typeVersion: 2.2 }),
    codeNode('Build Discord delivery request', [6040, -260], `
const payload = typeof $json.request_payload === 'string'
  ? JSON.parse($json.request_payload)
  : $json.request_payload;
if (!payload || typeof payload !== 'object' || Array.isArray(payload)) return [];
return [{ json: { digest_delivery_id: $json.digest_delivery_id, body: payload } }];`),
    httpNode('Send Discord digest once', [6260, -260], {
      method: 'POST', url: '={{ $env.DISCORD_TRANSFERS_WEBHOOK_URL + "?wait=true" }}', sendBody: true,
      contentType: 'json', specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.body) }}',
    }, { continueOnFail: true }),
    codeNode('Prepare delivery finalization', [6480, -260], `
const request = $('Build Discord delivery request').first().json;
const response = $json.body ?? $json;
const status = Number($json.statusCode ?? $json.status ?? 0);
const workflowRunId = $('Register workflow run').isExecuted
  ? $('Register workflow run').first().json.workflow_run_id
  : $('Register sample workflow run').first().json.workflow_run_id;
return [{ json: { params: [request.digest_delivery_id, status, String(response?.id ?? ''), JSON.stringify(response ?? {}), workflowRunId] } }];`),
    postgresNode('Finalize delivery and run', [6700, -260], `${finalizeDeliverySql()}\nUPDATE workflow_runs SET status = 'succeeded', finished_at = CURRENT_TIMESTAMP WHERE id = $5::bigint;`),
  ];
  const connections = {
    'Every six hours': { main: [[{ node: 'Recover interrupted deliveries', type: 'main', index: 0 }]] },
    'Manual run': { main: [[{ node: 'Recover interrupted deliveries', type: 'main', index: 0 }]] },
    'Manual sample run': { main: [[{ node: 'Recover interrupted sample deliveries', type: 'main', index: 0 }]] },
    'Recover interrupted deliveries': { main: [[{ node: 'Create run context', type: 'main', index: 0 }]] },
    'Recover interrupted sample deliveries': { main: [[{ node: 'Create sample run context', type: 'main', index: 0 }]] },
    'Create run context': { main: [[{ node: 'Register workflow run', type: 'main', index: 0 }]] },
    'Create sample run context': { main: [[{ node: 'Register sample workflow run', type: 'main', index: 0 }]] },
    'Register workflow run': { main: [[{ node: 'Load generated sources', type: 'main', index: 0 }]] },
    'Register sample workflow run': { main: [[{ node: 'Load sample source', type: 'main', index: 0 }]] },
    'Load generated sources': { main: [[{ node: 'Upsert source accounts', type: 'main', index: 0 }]] },
    'Load sample source': { main: [[{ node: 'Upsert sample source account', type: 'main', index: 0 }]] },
    'Upsert source accounts': { main: [[{ node: 'Select X collector', type: 'main', index: 0 }]] },
    'Upsert sample source account': { main: [[{ node: 'Load sample collected X posts', type: 'main', index: 0 }]] },
    'Select X collector': { main: [[{ node: 'Use twscrape collector', type: 'main', index: 0 }]] },
    'Use twscrape collector': { main: [[{ node: 'Build twscrape collect request', type: 'main', index: 0 }], [{ node: 'Build RapidAPI request', type: 'main', index: 0 }]] },
    'Build twscrape collect request': { main: [[{ node: 'Collect 20 X posts via twscrape', type: 'main', index: 0 }]] },
    'Collect 20 X posts via twscrape': { main: [[{ node: 'Normalize twscrape posts', type: 'main', index: 0 }]] },
    'Normalize twscrape posts': { main: [[{ node: 'Persist raw posts', type: 'main', index: 0 }]] },
    'Build RapidAPI request': { main: [[{ node: 'Collect 20 X posts', type: 'main', index: 0 }]] },
    'Collect 20 X posts': { main: [[{ node: 'Parse RapidAPI posts', type: 'main', index: 0 }]] },
    'Load sample collected X posts': { main: [[{ node: 'Parse RapidAPI posts', type: 'main', index: 0 }]] },
    'Parse RapidAPI posts': { main: [[{ node: 'Persist raw posts', type: 'main', index: 0 }]] },
    'Persist raw posts': { main: [[{ node: 'Build Qwen request', type: 'main', index: 0 }]] },
    'Build Qwen request': { main: [[{ node: 'Extract with Qwen', type: 'main', index: 0 }]] },
    'Extract with Qwen': { main: [[{ node: 'Validate Qwen response', type: 'main', index: 0 }]] },
    'Validate Qwen response': { main: [[{ node: 'Qwen response valid', type: 'main', index: 0 }]] },
    'Qwen response valid': { main: [[{ node: 'Transfer related', type: 'main', index: 0 }], [{ node: 'Record Qwen validation failure', type: 'main', index: 0 }]] },
    'Transfer related': { main: [[{ node: 'Merge extracted reports', type: 'main', index: 0 }], [{ node: 'Mark non-transfer ignored', type: 'main', index: 0 }]] },
    'Merge extracted reports': { main: [[{ node: 'Persist merged reports and revisions', type: 'main', index: 0 }]] },
    'Persist merged reports and revisions': { main: [[{ node: 'Prepare preferred source reset', type: 'main', index: 0 }]] },
    'Prepare preferred source reset': { main: [[{ node: 'Clear preferred report source', type: 'main', index: 0 }]] },
    'Clear preferred report source': { main: [[{ node: 'Set preferred report source', type: 'main', index: 0 }]] },
    'Set preferred report source': { main: [[{ node: 'Prepare enrichment batch query', type: 'main', index: 0 }]] },
    'Prepare enrichment batch query': { main: [[{ node: 'Enrichment enabled?', type: 'main', index: 0 }]] },
    'Enrichment enabled?': { main: [[{ node: 'Load player enrichment contexts', type: 'main', index: 0 }], [{ node: 'Prepare digest candidates query', type: 'main', index: 0 }]] },
    'Load player enrichment contexts': { main: [[{ node: 'Build soccerdata enrichment request', type: 'main', index: 0 }]] },
    'Build soccerdata enrichment request': { main: [[{ node: 'Refresh required?', type: 'main', index: 0 }]] },
    'Refresh required?': { main: [[{ node: 'Enrich players via soccerdata', type: 'main', index: 0 }], [{ node: 'Prepare digest candidates query', type: 'main', index: 0 }]] },
    'Enrich players via soccerdata': { main: [[{ node: 'Normalize soccerdata enrichment result', type: 'main', index: 0 }]] },
    'Normalize soccerdata enrichment result': { main: [[{ node: 'Persist soccerdata enrichment result', type: 'main', index: 0 }]] },
    'Persist soccerdata enrichment result': { main: [[{ node: 'Prepare digest candidates query', type: 'main', index: 0 }]] },
    'Prepare digest candidates query': { main: [[{ node: 'Find undelivered revisions', type: 'main', index: 0 }]] },
    'Find undelivered revisions': { main: [[{ node: 'Build bounded Discord digest', type: 'main', index: 0 }]] },
    'Build bounded Discord digest': { main: [[{ node: 'Reserve digest before delivery', type: 'main', index: 0 }]] },
    'Reserve digest before delivery': { main: [[{ node: 'Digest reserved', type: 'main', index: 0 }]] },
    'Digest reserved': { main: [[{ node: 'Build Discord delivery request', type: 'main', index: 0 }]] },
    'Build Discord delivery request': { main: [[{ node: 'Send Discord digest once', type: 'main', index: 0 }]] },
    'Send Discord digest once': { main: [[{ node: 'Prepare delivery finalization', type: 'main', index: 0 }]] },
    'Prepare delivery finalization': { main: [[{ node: 'Finalize delivery and run', type: 'main', index: 0 }]] },
  };
  return {
    id: 'football-transfer-monitor',
    name: 'Football Transfer Monitor',
    nodes,
    pinData: {},
    connections,
    active: false,
    settings: { executionOrder: 'v1', timezone: 'Asia/Ho_Chi_Minh', errorWorkflow: 'Football Transfer Monitor Errors' },
    versionId: '2.31.6',
    meta: { templateCredsSetupCompleted: false, instanceId: 'generated-without-secrets' },
    tags: [],
  };
}

function errorWorkflow() {
  const nodes = [
    node('Workflow error trigger', 'n8n-nodes-base.errorTrigger', [-440, 0], {}, { typeVersion: 1 }),
    codeNode('Prepare failure record', [-220, 0], `
const execution = $json.execution ?? {};
const error = $json.execution?.error ?? $json.error ?? {};
const executionId = String(execution.id ?? '');
const errorClass = String(error.name ?? 'WorkflowError');
const errorMessage = String(error.message ?? 'Unknown workflow error');
const fingerprint = (executionId || 'unknown') + '|' + errorMessage;
return [{ json: { params: [executionId, 'workflow_error', fingerprint, errorClass, errorMessage, JSON.stringify($json)] } }];`),
    postgresNode('Upsert workflow failure', [0, 0], `
WITH run AS (
  UPDATE workflow_runs
  SET status = 'failed', finished_at = COALESCE(finished_at, CURRENT_TIMESTAMP)
  WHERE workflow_name = 'football-transfer-monitor'
    AND external_execution_id = $1
    AND status IN ('running', 'failed')
  RETURNING id
), failure AS (
  INSERT INTO failures (workflow_run_id, operation_name, error_fingerprint, error_class, error_message, details)
  SELECT (SELECT id FROM run), $2, $3, $4, $5, $6::jsonb
  ON CONFLICT (workflow_run_id, operation_name, error_fingerprint) DO UPDATE
  SET occurrences = failures.occurrences + 1, last_seen_at = CURRENT_TIMESTAMP,
      error_message = EXCLUDED.error_message, details = EXCLUDED.details
  RETURNING id
)
SELECT failure.id::text AS failure_id, (SELECT id::text FROM run) AS workflow_run_id
FROM failure;`),
    httpNode('Send error webhook', [220, 0], {
      method: 'POST', url: '={{ $env.DISCORD_ERRORS_WEBHOOK_URL + "?wait=true" }}', sendBody: true,
      contentType: 'json', specifyBody: 'json', jsonBody: '={{ JSON.stringify({ content: "Football Transfer Monitor failed. Check n8n execution logs." }) }}',
    }, { continueOnFail: true }),
  ];
  return {
    id: 'football-transfer-monitor-errors',
    name: 'Football Transfer Monitor Errors', nodes, pinData: {}, active: false,
    connections: {
      'Workflow error trigger': { main: [[{ node: 'Prepare failure record', type: 'main', index: 0 }]] },
      'Prepare failure record': { main: [[{ node: 'Upsert workflow failure', type: 'main', index: 0 }]] },
      'Upsert workflow failure': { main: [[{ node: 'Send error webhook', type: 'main', index: 0 }]] },
    },
    settings: { executionOrder: 'v1', timezone: 'Asia/Ho_Chi_Minh' }, versionId: '2.31.6', tags: [],
  };
}

async function sameFile(path, content) {
  try { return await readFile(path, 'utf8') === content; } catch { return false; }
}

async function qwenPromptWithWomensBlacklist(prompt) {
  const names = (await readFile(womensBlacklistPath, 'utf8'))
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'));
  const uniqueNames = [...new Set(names)];
  const siblings = entityAliases.sibling_groups.map((group) => `- ${group.join(' / ')}`).join('\n');
  const commonSurnames = entityAliases.common_surnames.map((surname) => `- ${surname}`).join('\n');
  return `${prompt.trim()}\n\nWomen's-football blacklist:\n${uniqueNames.map((name) => `- ${name}`).join('\n')}\n\nIf a post names any player on this blacklist, including a case or diacritic variant, return {"transfer_related":false,"reports":[]}.\n\nKnown football siblings:\n${siblings}\n\nWhen a post uses a surname shared by listed siblings, use the full player name only when the post context identifies that sibling. Do not merge siblings or guess between them.\n\nNormalized common football surnames:\n${commonSurnames}\n\nFor a listed surname, preserve any first or given name stated in the post. Never invent a missing first name, and never reorder a surname-first name. The downstream JavaScript filter is authoritative for digest identity conflicts.`;
}

async function main() {
  const check = process.argv.includes('--check');
  const [registry, aliases] = await Promise.all([
    loadSourceRegistry(resolve(root, 'docs/journalist_list.md')),
    loadEntityAliases(entityAliasesPath),
  ]);
  entityAliases = aliases;
  const prompt = await qwenPromptWithWomensBlacklist(await readFile(resolve(here, 'qwen-system-prompt.md'), 'utf8'));
  const schema = JSON.parse(await readFile(resolve(here, 'qwen-response-schema.json'), 'utf8'));
  const files = [
    [outputPath, `${JSON.stringify(mainWorkflow({ registry, prompt, schema }), null, 2)}\n`],
    [errorOutputPath, `${JSON.stringify(errorWorkflow(), null, 2)}\n`],
  ];
  const stale = [];
  for (const [path, content] of files) {
    if (check) {
      if (!await sameFile(path, content)) stale.push(path);
    } else {
      await writeFile(path, content);
    }
  }
  if (stale.length) throw new Error(`Generated workflow files are stale: ${stale.join(', ')}. Run node workflow/build-workflows.mjs`);
  process.stdout.write(`${check ? 'Checked' : 'Generated'} ${registry.length} sources and ${files.length} workflow files.\n`);
}

await main();
