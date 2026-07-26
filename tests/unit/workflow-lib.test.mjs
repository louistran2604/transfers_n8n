import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  buildDiscordDigest,
  chooseClassification,
  dedupeKey,
  loadSourceRegistry,
  materialRevision,
  mergeReportGroup,
  parseRapidApiPosts,
  recoverInterruptedDelivery,
  retryDelayMs,
  selectDigestReports,
  shouldRetry,
  sourceMetadata,
  validateQwenResponse,
} from '../../workflow/lib.mjs';

const validReport = (overrides = {}) => ({
  player_name: 'Álvaro Test',
  player_identity_hint: null,
  current_club_name: 'Test FC',
  destination_club_name: 'Destination FC',
  classification: 'rumor',
  move_type: 'permanent',
  fee_amount: null,
  fee_currency: null,
  add_ons_amount: null,
  add_ons_currency: null,
  release_clause_amount: null,
  release_clause_currency: null,
  contract_length_months: null,
  contract_expires_on: null,
  loan_ends_on: null,
  has_option_to_buy: null,
  has_obligation_to_buy: null,
  sell_on_percentage: null,
  medical_status: 'not_reported',
  agreement_status: 'not_reported',
  confidence: 0.7,
  ...overrides,
});

const source = (username, account_type = 'individual') => sourceMetadata({
  username,
  display_name: username,
  external_account_id: '900000000000000001',
  account_type,
});

test('source parser returns all 77 sources and preserves large IDs as strings', async () => {
  const registry = await loadSourceRegistry(new URL('../../docs/journalist_list.md', import.meta.url));
  assert.equal(registry.length, 77);
  const harpur = registry.find((account) => account.username === 'charlotteharpur');
  assert.equal(harpur.external_account_id, '922928582866980864');
  assert.equal(typeof harpur.external_account_id, 'string');
  assert.deepEqual(source('realmadrid'), { platform: 'x', external_account_id: '900000000000000001', username: 'realmadrid', display_name: 'realmadrid', account_type: 'individual', is_official: true, priority_rank: 1, reliability_score: 1 });
  assert.equal(source('David_Ornstein').priority_rank, 2);
  assert.equal(source('BBCSport', 'organization').priority_rank, 3);
  assert.equal(source('someone').priority_rank, 4);
});

test('RapidAPI parser accepts direct and quoted tweets and ignores pure retweets', () => {
  const payload = { data: { entries: [
    { rest_id: '900000000000000101', legacy: { full_text: 'Direct transfer report', created_at: 'Sat Jul 26 00:00:00 +0000 2026' } },
    { rest_id: '900000000000000102', legacy: { full_text: 'A quote comment', created_at: 'Sat Jul 26 00:01:00 +0000 2026' }, quoted_status_result: { result: { legacy: { full_text: 'Original transfer report' } } } },
    { rest_id: '900000000000000103', legacy: { full_text: 'RT @source: old transfer report', created_at: 'Sat Jul 26 00:02:00 +0000 2026', retweeted_status_result: { result: {} } } },
  ] } };
  const posts = parseRapidApiPosts(payload, source('David_Ornstein'));
  assert.equal(posts.length, 2);
  assert.equal(posts[1].is_quote, true);
  assert.match(posts[1].content, /Original transfer report/);
  assert.equal(posts[0].external_post_id, '900000000000000101');
});

test('strict Qwen validation rejects extra properties, invalid currencies, and missing fields', () => {
  const accepted = { transfer_related: true, reports: [validReport()] };
  assert.equal(validateQwenResponse(accepted).valid, true);
  assert.equal(validateQwenResponse({ ...accepted, source_url: 'https://bad.example' }).valid, false);
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [validReport({ fee_currency: 'eur' })] }).valid, false);
  const missing = validReport();
  delete missing.player_name;
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [missing] }).valid, false);
});

test('merging uses source tier, fills missing fields, keeps conflicts, and creates only material revisions', () => {
  const tierTwo = source('David_Ornstein');
  const tierFour = source('someone');
  const merged = mergeReportGroup([
    { ...validReport({ fee_amount: null, classification: 'rumor', confidence: 0.6 }), source: tierTwo, raw_post_id: '1', post_url: 'https://x.com/a/status/1', posted_at: '2026-07-26T00:00:00.000Z' },
    { ...validReport({ fee_amount: 45000000, fee_currency: 'EUR', classification: 'advanced_negotiations', confidence: 0.8 }), source: tierFour, raw_post_id: '2', post_url: 'https://x.com/b/status/2', posted_at: '2026-07-26T01:00:00.000Z' },
  ]);
  assert.equal(merged.preferred_source.username, 'David_Ornstein');
  assert.equal(merged.fee_amount, 45000000);
  assert.equal(merged.classification, 'advanced_negotiations');
  assert.equal(merged.normalized_data.conflicts.classification.length, 2);
  const first = materialRevision(null, merged);
  assert.equal(first.changed, true);
  assert.equal(materialRevision(first.content_sha256, { ...merged, sources: [] }).changed, false);
  assert.equal(materialRevision(first.content_sha256, { ...merged, fee_amount: 50000000 }).changed, true);
  assert.equal(dedupeKey(merged), 'alvaro-test|test-fc|destination-fc');
  assert.equal(chooseClassification(['rumor', 'loan', 'contract_renewal']), 'contract_renewal');
});

test('retry timing honors server headers within a bounded exponential backoff policy', () => {
  assert.equal(retryDelayMs({ attempt: 1, retryAfter: '3', now: 0 }), 3000);
  assert.equal(retryDelayMs({ attempt: 3, retryAfter: null, now: 0 }), 4000);
  assert.equal(retryDelayMs({ attempt: 1, rateResetEpochSeconds: 10, now: 0 }), 10000);
  assert.equal(retryDelayMs({ attempt: 1, retryAfter: '99999', maximumMs: 300000, now: 0 }), 300000);
  assert.equal(shouldRetry('rapidapi', 503), true);
  assert.equal(shouldRetry('qwen', 0), true);
  assert.equal(shouldRetry('discord', 400), false);
  assert.equal(shouldRetry('discord', 429), true);
});

test('digest selection allows only eligible positions 16 through 18 and respects Discord limits', () => {
  const reports = Array.from({ length: 22 }, (_, index) => ({
    ...validReport({ player_name: `Player ${index}`, classification: index >= 15 && index < 19 ? 'official_confirmed' : 'advanced_negotiations', confidence: 0.9 }),
    preferred_source: { ...source(index >= 15 ? 'BBCSport' : 'David_Ornstein', index >= 15 ? 'organization' : 'individual'), display_name: 'Source' },
    sources: [{ post_url: `https://x.com/source/status/${900000000000000000n + BigInt(index)}` }],
    last_reported_at: `2026-07-26T${String(index % 24).padStart(2, '0')}:00:00.000Z`,
  }));
  const selected = selectDigestReports(reports);
  assert.equal(selected.length, 18);
  assert.ok(selected.slice(15).every((report) => report.classification === 'official_confirmed'));
  const payload = buildDiscordDigest(reports);
  assert.ok(payload.embeds.length <= 10);
  assert.ok(payload.embeds[0].fields.length <= 25);
  assert.ok(payload.embeds[0].fields.every((field) => field.value.length <= 1024));
  const size = payload.embeds[0].title.length + payload.embeds[0].fields.reduce((total, field) => total + field.name.length + field.value.length, 0);
  assert.ok(size <= 6000);
});

test('digest displays every meaningful non-null transfer detail', () => {
  const report = {
    ...validReport({
      player_identity_hint: 'Senior Spain international',
      move_type: 'loan',
      fee_amount: 25000000,
      fee_currency: 'EUR',
      add_ons_amount: 5000000,
      add_ons_currency: 'EUR',
      release_clause_amount: 80000000,
      release_clause_currency: 'EUR',
      contract_length_months: 48,
      contract_expires_on: '2030-06-30',
      loan_ends_on: '2027-06-30',
      has_option_to_buy: true,
      has_obligation_to_buy: false,
      sell_on_percentage: 15,
      medical_status: 'scheduled',
      agreement_status: 'reached',
    }),
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    sources: [{ post_url: 'https://x.com/David_Ornstein/status/999000000000000001' }],
  };
  const value = buildDiscordDigest([report]).embeds[0].fields[0].value;
  for (const expected of [
    'Identity: Senior Spain international',
    'Move: loan',
    'Fee: 25,000,000 EUR',
    'Add-ons: 5,000,000 EUR',
    'Release clause: 80,000,000 EUR',
    'Contract length: 48 months',
    'Contract expires: 2030-06-30',
    'Loan ends: 2027-06-30',
    'Option to buy: Yes',
    'Obligation to buy: No',
    'Sell-on: 15%',
    'Medical: scheduled',
    'Agreement: reached',
  ]) assert.match(value, new RegExp(expected.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
});

test('interrupted sending deliveries become unknown and cannot be automatically resent', () => {
  assert.deepEqual(recoverInterruptedDelivery({ id: '1', status: 'sending' }), { id: '1', status: 'unknown', retryable: false });
  assert.deepEqual(recoverInterruptedDelivery({ id: '2', status: 'pending' }), { id: '2', status: 'pending', retryable: true });
});

test('generated merge node hashes snapshots without the Web Crypto global', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const mergeNode = workflow.nodes.find((node) => node.name === 'Merge extracted reports');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runMerge = new AsyncFunction('$input', `const crypto = undefined;\n${mergeNode.parameters.jsCode}`);
  const report = { ...validReport(), raw_post_id: '1', post_url: 'https://x.com/test/status/1', posted_at: '2026-07-26T00:00:00.000Z', source: source('David_Ornstein') };
  const output = await runMerge({ all: () => [{ json: { report } }] });
  const payload = JSON.parse(output[0].json.params[0]);
  const expected = createHash('sha256').update(JSON.stringify(payload.snapshot)).digest('hex');
  assert.equal(payload.content_sha256, expected);
});

test('generated digest node ignores n8n no-row placeholders', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const output = await runDigest({ all: () => [{ json: { success: true } }] });
  assert.deepEqual(output, []);
});

test('generated workflow stays in sync with the registry and extraction contract', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const sourceNode = workflow.nodes.find((node) => node.name === 'Load generated sources');
  const qwenNode = workflow.nodes.find((node) => node.name === 'Build Qwen request');
  const rapidApiBuilderNode = workflow.nodes.find((node) => node.name === 'Build RapidAPI request');
  const rapidApiNode = workflow.nodes.find((node) => node.name === 'Collect 20 X posts');
  const rapidApiParserNode = workflow.nodes.find((node) => node.name === 'Parse RapidAPI posts');
  const qwenParserNode = workflow.nodes.find((node) => node.name === 'Validate Qwen response');
  const sampleNode = workflow.nodes.find((node) => node.name === 'Load sample collected X posts');
  const reserveNode = workflow.nodes.find((node) => node.name === 'Reserve digest before delivery');
  const candidatesNode = workflow.nodes.find((node) => node.name === 'Find undelivered revisions');
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const runNode = workflow.nodes.find((node) => node.name === 'Register workflow run');
  const recoveryNode = workflow.nodes.find((node) => node.name === 'Recover interrupted deliveries');
  assert.match(sourceNode.parameters.jsCode, /922928582866980864/);
  assert.match(qwenNode.parameters.jsCode, /football_transfer_extraction/);
  assert.doesNotMatch(rapidApiBuilderNode.parameters.jsCode, /\$env/);
  assert.match(rapidApiNode.parameters.url, /RAPIDAPI_BASE_URL/);
  assert.doesNotMatch(rapidApiParserNode.parameters.jsCode, /itemMatching/);
  assert.match(rapidApiParserNode.parameters.jsCode, /\$\('Build RapidAPI request'\)\.all\(\)/);
  assert.doesNotMatch(qwenParserNode.parameters.jsCode, /itemMatching/);
  assert.match(qwenNode.parameters.jsCode, /delete llamaSchema\.properties\.reports\.items\.properties\.player_name\.minLength/);
  assert.match(qwenParserNode.parameters.jsCode, /report\.player_name\.trim\(\)\.length > 0/);
  assert.doesNotMatch(workflow.nodes.find((node) => node.name === 'Prepare delivery finalization').parameters.jsCode, /itemMatching/);
  assert.match(sampleNode.parameters.jsCode, /TEST DATA/);
  assert.ok(workflow.connections['Manual sample run']);
  assert.match(reserveNode.parameters.query, /status = 'sending'/);
  assert.doesNotMatch(reserveNode.parameters.query, /sending AS/);
  assert.match(candidatesNode.parameters.query, /pending_candidates/);
  assert.match(digestNode.parameters.jsCode, /pending_idempotency_key/);
  assert.match(digestNode.parameters.jsCode, /typeof snapshot\.classification !== 'string'/);
  assert.equal(runNode.parameters.options.queryReplacement, '={{ $json.params }}');
  assert.equal(recoveryNode.parameters.options.queryReplacement, undefined);
  assert.equal(workflow.settings.timezone, 'Asia/Ho_Chi_Minh');
});
