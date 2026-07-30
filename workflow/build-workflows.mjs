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

function postgresNode(name, position, query, queryReplacement) {
  const options = {
    queryBatching: 'transaction',
    outputLargeFormatNumbers: 'text',
  };
  if (/\$\d+\b/.test(query)) options.queryReplacement = queryReplacement ?? '={{ $json.params }}';
  return node(name, 'n8n-nodes-base.postgres', position, {
    operation: 'executeQuery',
    query,
    options,
  }, { credentials: postgresCredential });
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
  SET player_id = EXCLUDED.player_id, reported_player_name = EXCLUDED.reported_player_name,
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

function candidatesSql() {
  return `
WITH pending_candidates AS (
  SELECT r.id::text AS revision_id, r.snapshot,
    s.priority_rank, s.reliability_score, s.is_official, s.username AS source_username, s.display_name AS source_name,
    p.post_url, p.posted_at,
    dd.idempotency_key AS pending_idempotency_key,
    dd.window_started_at AS pending_window_started_at,
    dd.window_ended_at AS pending_window_ended_at
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
  NULL::timestamptz AS pending_window_ended_at
FROM latest_revisions r
JOIN transfer_reports tr ON tr.id = r.transfer_report_id
JOIN transfer_report_sources trs ON trs.transfer_report_id = tr.id AND trs.is_preferred
JOIN raw_posts p ON p.id = trs.raw_post_id
JOIN source_accounts s ON s.id = p.source_account_id
LEFT JOIN digest_items di ON di.transfer_report_revision_id = r.id
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
    status, attempt_count, first_attempted_at, last_attempted_at
  )
  SELECT payload->>'idempotency_key', 'transfers', (payload->>'window_started_at')::timestamptz, (payload->>'window_ended_at')::timestamptz,
    'sending', 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
  FROM input
  ON CONFLICT (idempotency_key) DO UPDATE
  SET status = 'sending', attempt_count = digest_deliveries.attempt_count + 1,
      first_attempted_at = COALESCE(digest_deliveries.first_attempted_at, CURRENT_TIMESTAMP),
      last_attempted_at = CURRENT_TIMESTAMP, updated_at = CURRENT_TIMESTAMP
  WHERE digest_deliveries.status = 'pending'
  RETURNING id, status
),
claimed AS (
  INSERT INTO digest_items (digest_delivery_id, transfer_report_revision_id, position)
  SELECT (SELECT id FROM delivery), revision_id::bigint, position::smallint
  FROM input, jsonb_array_elements_text(input.payload->'revision_ids') WITH ORDINALITY AS selected(revision_id, position)
  WHERE (SELECT status FROM delivery) = 'sending'
  ON CONFLICT (transfer_report_revision_id) DO NOTHING
  RETURNING id
)
SELECT id::text AS digest_delivery_id, status FROM delivery
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
const required = ${JSON.stringify(['player_name', 'player_identity_hint', 'current_club_name', 'destination_club_name', 'classification', 'move_type', 'fee_amount', 'fee_currency', 'add_ons_amount', 'add_ons_currency', 'release_clause_amount', 'release_clause_currency', 'contract_length_months', 'contract_expires_on', 'loan_ends_on', 'has_option_to_buy', 'has_obligation_to_buy', 'sell_on_percentage', 'medical_status', 'agreement_status', 'is_huge_rumor', 'is_digest_worthy', 'confidence'])};
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
  if (parsed && Array.isArray(parsed.reports)) parsed.reports = parsed.reports.map((report) => canonicalizeReport({ ...report, current_club_name: nullableClub(report.current_club_name), destination_club_name: nullableClub(report.destination_club_name) }));
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
  const snapshot = Object.fromEntries(${JSON.stringify(['player_name', 'player_identity_hint', 'current_club_name', 'destination_club_name', 'classification', 'move_type', 'fee_amount', 'fee_currency', 'add_ons_amount', 'add_ons_currency', 'release_clause_amount', 'release_clause_currency', 'contract_length_months', 'contract_expires_on', 'loan_ends_on', 'has_option_to_buy', 'has_obligation_to_buy', 'sell_on_percentage', 'medical_status', 'agreement_status', 'is_huge_rumor', 'is_digest_worthy', 'confidence'])}.map((field) => [field, merged[field] ?? null]));
  snapshot.dedupe_key = merged.dedupe_key;
  const payload = {
    ...snapshot,
    player_identity_key: normalize(merged.player_name).replace(/\\s/g, '-'),
    normalized_player_name: normalize(merged.player_name),
    first_reported_at: merged.first_reported_at,
    last_reported_at: merged.last_reported_at,
    normalized_data: { conflicts },
    preferred_raw_post_id: String(best.raw_post_id),
    sources: reports.map((report) => ({ raw_post_id: String(report.raw_post_id), posted_at: report.posted_at, post_url: report.post_url, source: report.source })),
    snapshot,
    content_sha256: sha256(Object.fromEntries(Object.entries(snapshot).filter(([field]) => field !== 'is_digest_worthy'))),
  };
  outputs.push({ json: { params: [JSON.stringify(payload)] } });
}
return outputs;`;
}

function digestCode() {
  return `
${entityAliasHelpers()}
const precedence = { contract_renewal: 6, rejected_failed: 5, loan: 4, official_confirmed: 3, advanced_negotiations: 2, rumor: 1 };
const truncate = (value, maximum) => String(value ?? '').length <= maximum ? String(value ?? '') : String(value ?? '').slice(0, maximum - 1) + '…';
const amount = (value, currency) => value === null || value === undefined ? null : (Number(value).toLocaleString('en-US') + ' ' + (currency ?? '')).trim();
const hasNamedClub = (value) => typeof value === 'string' && value.trim().length > 0 && !/^(not[ _-]?reported|unknown|n\\/?a)$/i.test(value.trim());
const isDigestEligible = (report) => report.is_digest_worthy === true && hasNamedClub(report.current_club_name) && hasNamedClub(report.destination_club_name);
const digestStoryKey = (report) => [report.player_name, report.destination_club_name].map(normalizeAlias).join('|');
const digestUpdateFields = ['classification', 'move_type', 'fee_amount', 'fee_currency', 'add_ons_amount', 'add_ons_currency', 'release_clause_amount', 'release_clause_currency', 'contract_length_months', 'contract_expires_on', 'loan_ends_on', 'has_option_to_buy', 'has_obligation_to_buy', 'sell_on_percentage', 'medical_status', 'agreement_status', 'confidence'];
const digestMaterialKey = (report) => JSON.stringify(Object.fromEntries(digestUpdateFields.map((field) => [field, report[field] ?? null])));
const sameDigestStory = (left, right) => digestStoryKey(left) === digestStoryKey(right);
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
  return canonicalizeReport({ ...snapshot, revision_id: item.revision_id, post_url: item.post_url, pending_idempotency_key: item.pending_idempotency_key, pending_window_started_at: item.pending_window_started_at, pending_window_ended_at: item.pending_window_ended_at, sent_history: sentHistory, preferred_source: { priority_rank: Number(item.priority_rank), reliability_score: Number(item.reliability_score), username: item.source_username, display_name: item.source_name } });
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
const seenStoryKeys = new Set();
const distinctCandidateReports = candidateReports.filter((report) => {
  const revisionId = String(report.revision_id ?? '');
  const storyKey = digestStoryKey(report);
  if (!revisionId || seenRevisionIds.has(revisionId) || seenStoryKeys.has(storyKey)) return false;
  seenRevisionIds.add(revisionId);
  seenStoryKeys.add(storyKey);
  return true;
});
const selected = [...distinctCandidateReports.slice(0, 15), ...distinctCandidateReports.slice(15).filter((report) => digestPriority(report) < 2).slice(0, 3)];
let total = 45;
const fields = [];
for (const report of selected) {
  const name = truncate(String(fields.length + 1) + '. ' + report.player_name, 256);
  const details = [
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
    report.post_url ? '[' + report.preferred_source.display_name + '](' + report.post_url + ')' : report.preferred_source.display_name,
  ];
  const value = truncate(details.filter(Boolean).join('\\n'), 1024);
  if (fields.length >= 25 || total + name.length + value.length > 6000) continue;
  total += name.length + value.length;
  fields.push({ name, value, inline: false, revision_id: report.revision_id });
}
const now = new Date();
const start = new Date(now); start.setMinutes(0, 0, 0); start.setHours(Math.floor(start.getHours() / 6) * 6);
const end = new Date(start.valueOf() + 6 * 60 * 60 * 1000);
const payload = { allowed_mentions: { parse: [] }, embeds: [{ title: 'Football transfer digest', color: 1948592, fields: fields.map(({ revision_id, ...field }) => field), footer: { text: String(fields.length) + ' new material report' + (fields.length === 1 ? '' : 's') } }] };
return fields.length ? [{ json: { params: [JSON.stringify({ idempotency_key: pending?.pending_idempotency_key ?? 'transfer-digest|' + start.toISOString(), window_started_at: pending?.pending_window_started_at ?? start.toISOString(), window_ended_at: pending?.pending_window_ended_at ?? end.toISOString(), revision_ids: fields.map((field) => field.revision_id), discord_payload: payload })] } }] : [];`;
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
  body: { model: 'qwen3.6-27b', temperature: 0, messages: [{ role: 'system', content: prompt }, { role: 'user', content: item.json.content }], response_format: { type: 'json_schema', json_schema: { name: 'football_transfer_extraction', strict: true, schema: llamaSchema } } }
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
    codeNode('Prepare digest candidates query', [3180, -180], `
const context = $('Create run context').isExecuted ? $('Create run context').first().json : $('Create sample run context').first().json;
return [{ json: { params: [context.collection_cutoff_at, context.collection_started_at] } }];`),
    postgresNode('Find undelivered revisions', [3400, -180], candidatesSql()),
    codeNode('Build bounded Discord digest', [3620, -180], digestCode()),
    postgresNode('Reserve digest before delivery', [3840, -180], reserveDigestSql()),
    node('Digest reserved', 'n8n-nodes-base.if', [4060, -180], { conditions: { options: { caseSensitive: true, leftValue: '', typeValidation: 'strict' }, conditions: [{ leftValue: '={{ !!$json.digest_delivery_id }}', rightValue: true, operator: { type: 'boolean', operation: 'true', singleValue: true } }], combinator: 'and' } }, { typeVersion: 2.2 }),
    codeNode('Build Discord delivery request', [4280, -260], `
const digest = $('Build bounded Discord digest').first().json.params[0];
const payload = typeof digest === 'string' ? JSON.parse(digest) : digest;
return [{ json: { digest_delivery_id: $json.digest_delivery_id, body: payload.discord_payload } }];`),
    httpNode('Send Discord digest once', [4500, -260], {
      method: 'POST', url: '={{ $env.DISCORD_TRANSFERS_WEBHOOK_URL + "?wait=true" }}', sendBody: true,
      contentType: 'json', specifyBody: 'json', jsonBody: '={{ JSON.stringify($json.body) }}',
    }, { continueOnFail: true }),
    codeNode('Prepare delivery finalization', [4720, -260], `
const request = $('Build Discord delivery request').first().json;
const response = $json.body ?? $json;
const status = Number($json.statusCode ?? $json.status ?? 0);
const workflowRunId = $('Register workflow run').isExecuted
  ? $('Register workflow run').first().json.workflow_run_id
  : $('Register sample workflow run').first().json.workflow_run_id;
return [{ json: { params: [request.digest_delivery_id, status, String(response?.id ?? ''), JSON.stringify(response ?? {}), workflowRunId] } }];`),
    postgresNode('Finalize delivery and run', [4940, -260], `${finalizeDeliverySql()}\nUPDATE workflow_runs SET status = 'succeeded', finished_at = CURRENT_TIMESTAMP WHERE id = $5::bigint;`),
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
    'Set preferred report source': { main: [[{ node: 'Prepare digest candidates query', type: 'main', index: 0 }]] },
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
    versionId: '2.16.1',
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
const fingerprint = String(execution.id ?? 'unknown') + '|' + String(error.message ?? 'Unknown workflow error');
return [{ json: { params: [String(execution.id ?? ''), 'workflow_error', fingerprint, error.name ?? 'WorkflowError', error.message ?? 'Unknown workflow error', JSON.stringify($json)] } }];`),
    postgresNode('Upsert workflow failure', [0, 0], `
INSERT INTO failures (operation_name, error_fingerprint, error_class, error_message, details)
VALUES ($2, $3, $4, $5, $6::jsonb)
ON CONFLICT (workflow_run_id, operation_name, error_fingerprint) DO UPDATE
SET occurrences = failures.occurrences + 1, last_seen_at = CURRENT_TIMESTAMP,
    error_message = EXCLUDED.error_message, details = EXCLUDED.details
RETURNING id::text AS failure_id;`),
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
    settings: { executionOrder: 'v1', timezone: 'Asia/Ho_Chi_Minh' }, versionId: '2.16.1', tags: [],
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
  return `${prompt.trim()}\n\nWomen's-football blacklist:\n${uniqueNames.map((name) => `- ${name}`).join('\n')}\n\nIf a post names any player on this blacklist, including a case or diacritic variant, return {"transfer_related":false,"reports":[]}.\n\nKnown football siblings:\n${siblings}\n\nWhen a post uses a surname shared by listed siblings, use the full player name only when the post context identifies that sibling. Do not merge siblings or guess between them.`;
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
