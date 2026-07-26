import assert from 'node:assert/strict';
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

for (const mode of ['malformed', 'invalid']) {
  const result = await json(`/qwen/${mode}`);
  const content = result.body.choices[0].message.content;
  const extracted = (() => { try { return JSON.parse(content); } catch { return null; } })();
  assert.equal(validateQwenResponse(extracted).valid, false);
}
const valid = await json('/qwen/valid');
assert.equal(validateQwenResponse(JSON.parse(valid.body.choices[0].message.content)).valid, true);

const reports = Array.from({ length: 20 }, (_, index) => ({
  player_name: `Mock Player ${index}`, current_club_name: 'Mock FC', destination_club_name: 'Test United',
  classification: index > 14 ? 'official_confirmed' : 'rumor', move_type: 'permanent', confidence: 0.8,
  fee_amount: null, fee_currency: null, medical_status: 'not_reported',
  preferred_source: { ...sourceMetadata({ username: index > 14 ? 'realmadrid' : 'someone', display_name: 'Mock Source', external_account_id: String(900000000000000000n + BigInt(index)), account_type: 'individual' }), display_name: 'Mock Source' },
  sources: [{ post_url: `https://x.com/mock/status/${900000000000000000n + BigInt(index)}` }],
}));
const digest = buildDiscordDigest(reports);
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
