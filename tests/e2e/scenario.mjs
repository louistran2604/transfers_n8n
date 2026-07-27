import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  buildDiscordDigest,
  recoverInterruptedDelivery,
  retryDelayMs,
  shouldRetry,
  sourceMetadata,
  validateQwenResponse,
} from '../../workflow/lib.mjs';

const base = process.env.MOCK_BASE_URL ?? 'http://127.0.0.1:18081';
const json = async (path, options) => {
  const response = await fetch(`${base}${path}`, options);
  return { response, body: await response.json().catch(() => null) };
};

await json('/state/reset');

const firstRate = await json('/rapid/rate');
assert.equal(firstRate.response.status, 429);
assert.equal(retryDelayMs({ attempt: 1, retryAfter: firstRate.response.headers.get('retry-after') }), 1000);
assert.equal(shouldRetry('rapidapi', firstRate.response.status), true);
assert.equal((await json('/rapid/rate')).response.status, 200);

for (let attempt = 1; attempt <= 5; attempt += 1) {
  const failure = await json('/rapid/fail');
  assert.equal(failure.response.status, 503);
  assert.equal(shouldRetry('rapidapi', failure.response.status), true);
}
assert.equal((await json('/state')).body.rapidFail, 5);

const twscrapeRequest = {
  sources: [
    { source_id: 'source-1', username: 'mock_source', x_user_id: '330262748' },
    { source_id: 'source-2', username: 'unavailable_source', x_user_id: '330262749' },
  ],
  limit: 20,
};
const twscrapeCollected = await json('/twscrape/collect', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(twscrapeRequest) });
assert.equal(twscrapeCollected.response.status, 200);
assert.equal(twscrapeCollected.body.posts.length, 3);
assert.equal(twscrapeCollected.body.errors.length, 1);
assert.equal(twscrapeCollected.body.posts[0].x_user_id, '330262748');
assert.equal(typeof twscrapeCollected.body.posts[0].external_post_id, 'string');
const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
const twscrapeAdapter = workflow.nodes.find((node) => node.name === 'Normalize twscrape posts');
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const runTwscrapeAdapter = new AsyncFunction('$input', '$', twscrapeAdapter.parameters.jsCode);
const twscrapeOutput = await runTwscrapeAdapter({ first: () => ({ json: { body: twscrapeCollected.body } }) }, (name) => {
  if (name === 'Create run context') return { isExecuted: true, first: () => ({ json: { collection_cutoff_at: '2026-07-27T00:00:00.000Z', collection_started_at: '2026-07-27T06:00:00.000Z' } }) };
  if (name === 'Create sample run context') return { isExecuted: false };
  assert.equal(name, 'Build twscrape collect request');
  return { first: () => ({ json: {
    sources: [{ source_id: 'source-1', external_account_id: '330262748', username: 'mock_source', display_name: 'Mock Source', priority_rank: 4, reliability_score: 0.7, is_official: false }],
  } }) };
});
assert.equal(twscrapeOutput.length, 1);
assert.equal(twscrapeOutput[0].json.params[0], '330262748');
assert.match(twscrapeOutput[0].json.params[3], /Mock quoted transfer report/);
assert.equal((await json('/state')).body.twscrapeCalls, 1);

for (const mode of ['malformed', 'invalid']) {
  const result = await json(`/qwen/${mode}`);
  const content = result.body.choices[0].message.content;
  const extracted = (() => { try { return JSON.parse(content); } catch { return null; } })();
  assert.equal(validateQwenResponse(extracted).valid, false);
}
const valid = await json('/qwen/valid');
assert.equal(validateQwenResponse(JSON.parse(valid.body.choices[0].message.content)).valid, true);
const women = await json('/qwen/women');
const womenExtraction = JSON.parse(women.body.choices[0].message.content);
assert.equal(validateQwenResponse(womenExtraction).valid, true);
assert.equal(womenExtraction.transfer_related, false);

const reports = Array.from({ length: 20 }, (_, index) => ({
  player_name: `Mock Player ${index}`, current_club_name: 'Mock FC', destination_club_name: 'Test United',
  classification: index > 14 ? 'official_confirmed' : 'rumor', move_type: 'permanent', confidence: 0.8,
  fee_amount: null, fee_currency: null, medical_status: 'not_reported', is_huge_rumor: false,
  preferred_source: { ...sourceMetadata({ username: index > 14 ? 'someone' : 'David_Ornstein', display_name: 'Mock Source', external_account_id: String(900000000000000000n + BigInt(index)), account_type: 'individual' }), display_name: 'Mock Source' },
  sources: [{ post_url: `https://x.com/mock/status/${900000000000000000n + BigInt(index)}` }],
}));
reports.push(...reports.slice(0, 3));
const digest = buildDiscordDigest(reports);
assert.equal(digest.embeds[0].fields.length, 18);
assert.equal(new Set(digest.embeds[0].fields.map((field) => field.name)).size, 18);
const sent = await json('/discord/receive', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(digest) });
assert.equal(sent.response.status, 200);
assert.match(sent.body.id, /^mock-discord-/);

const interrupted = await fetch(`${base}/discord/receive?simulateTerminate=1`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(digest) }).catch(() => null);
assert.equal(interrupted, null);
const recovered = recoverInterruptedDelivery({ status: 'sending' });
assert.equal(recovered.status, 'unknown');
assert.equal(recovered.retryable, false);
assert.equal((await json('/state')).body.discordRequests, 2);

process.stdout.write('Mock E2E scenarios passed.\n');
