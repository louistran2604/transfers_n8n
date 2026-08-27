import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import {
  buildEnrichmentRequest,
  buildDiscordDigest,
  loadEntityAliases,
  normalizeEnrichmentResponse,
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
assert.equal((await json('/state')).body.sofascoreCalls, 0);

const enrichmentContext = {
  transfer_report_id: '100',
  reported_player_name: 'Kylian Mbappé',
  current_club_name: 'Real Madrid',
  destination_club_name: 'Liverpool',
  classification: 'rumor',
  move_type: 'permanent',
  provider_player_id: '826643',
  aliases: [],
  identity_overrides: [],
  profile_fresh_until: null,
  statistics_fresh_until: null,
  team_mapping_fresh: false,
  season_mapping_fresh: false,
};
const off = buildEnrichmentRequest([enrichmentContext], { mode: 'off', requestId: 'off' });
assert.equal(off.request, null);
assert.equal((await json('/state')).body.sofascoreCalls, 0);

const callEnrichment = async (requestId, context = enrichmentContext, options = {}) => {
  const prepared = buildEnrichmentRequest([context], { mode: 'active', requestId });
  const result = await json('/v1/enrich', {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(prepared.request),
    ...options,
  });
  return { prepared, result, normalized: normalizeEnrichmentResponse(prepared.request, {
    statusCode: result.response.status,
    body: result.body,
  }) };
};

const shadow = await callEnrichment('shadow-success');
assert.equal(shadow.normalized.items[0].status, 'fresh');
const transferOnlyReport = {
  player_name: 'Kylian Mbappé', current_club_name: 'Real Madrid', destination_club_name: 'Liverpool',
  classification: 'rumor', move_type: 'permanent', confidence: 0.8,
  fee_amount: null, fee_currency: null, medical_status: 'not_reported', is_huge_rumor: false, is_digest_worthy: true,
  preferred_source: { ...sourceMetadata({ username: 'David_Ornstein', display_name: 'David Ornstein', external_account_id: '1', account_type: 'individual', source_kind: 'journalist', publisher_group_key: 'reporter:david-ornstein', is_aggregator: false, seed_reliability: 0.95 }), display_name: 'David Ornstein' },
  sources: [{ post_url: 'https://x.com/David_Ornstein/status/999000000000000301' }],
};
const shadowValue = buildDiscordDigest([transferOnlyReport]).embeds[0].fields[0].value;
assert.doesNotMatch(shadowValue, /Sofascore|LaLiga|Profile/);

const active = await callEnrichment('active-success');
const activeItem = active.normalized.items[0];
const activeEnrichment = {
  profile: {
    ...activeItem.profile,
    current_club_name: activeItem.profile.current_club.name,
  },
  statistics: {
    ...activeItem.statistics,
    competition_name: activeItem.statistics.competition,
    season_label: activeItem.statistics.season,
    minutes_per_appearance: activeItem.statistics.minutes_per_game,
  },
};
const activeValue = buildDiscordDigest([{ ...transferOnlyReport, enrichment: activeEnrichment }]).embeds[0].fields[0].value;
assert.match(activeValue, /Profile: Real Madrid/);
assert.match(activeValue, /LaLiga 2025\/26 - all clubs/);

const sparse = await callEnrichment('active-sparse', {
  ...enrichmentContext,
  transfer_report_id: '101',
  reported_player_name: 'Nguyễn Quang Hải',
  provider_player_id: '845067',
});
assert.equal(sparse.normalized.items[0].statistics.expected_goals, null);
const ambiguous = await callEnrichment('active-ambiguous', {
  ...enrichmentContext,
  transfer_report_id: '102',
  reported_player_name: 'John Smith',
  provider_player_id: null,
});
assert.equal(ambiguous.normalized.items[0].status, 'ambiguous');
assert.equal(ambiguous.normalized.items[0].identity, null);
const malformed = await callEnrichment('active-malformed');
assert.equal(malformed.normalized.items[0].status, 'schema_failure');

const timeoutPrepared = buildEnrichmentRequest([enrichmentContext], { mode: 'active', requestId: 'active-timeout' });
const timeoutResponse = await fetch(`${base}/v1/enrich`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(timeoutPrepared.request),
  signal: AbortSignal.timeout(50),
}).then(async (response) => ({ statusCode: response.status, body: await response.json() })).catch(() => ({ error: true }));
const timeoutNormalized = normalizeEnrichmentResponse(timeoutPrepared.request, timeoutResponse);
assert.equal(timeoutNormalized.items[0].status, 'schema_failure');

const allFailure = await callEnrichment('active-all-failure');
assert.equal(allFailure.result.response.status, 200);
assert.equal(allFailure.normalized.items[0].status, 'provider_failure');
const failureDigest = buildDiscordDigest([{
  ...transferOnlyReport,
  enrichment: {
    profile: allFailure.normalized.items[0].profile,
    statistics: allFailure.normalized.items[0].statistics,
    error: allFailure.normalized.items[0].error,
  },
}]);
assert.equal(failureDigest.embeds[0].fields[0].value, shadowValue);
const discordBeforeFailure = (await json('/state')).body.discordRequests;
assert.equal((await json('/discord/receive', {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(failureDigest),
})).response.status, 200);
assert.equal((await json('/state')).body.discordRequests, discordBeforeFailure + 1);

const exactBoundaryPayload = {
  embeds: Array.from({ length: 10 }, () => ({
    title: 'x',
    fields: Array.from({ length: 25 }, () => ({ name: 'n', value: 'v' })),
  })),
};
assert.equal((await json('/discord/receive', {
  method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(exactBoundaryPayload),
})).response.status, 200);
for (const invalidPayload of [
  { embeds: Array.from({ length: 11 }, () => ({})) },
  { embeds: [{ fields: Array.from({ length: 26 }, () => ({ name: 'n', value: 'v' })) }] },
  { embeds: [{ fields: [{ name: 'n'.repeat(257), value: 'v' }] }] },
  { embeds: [{ fields: [{ name: 'n', value: 'v'.repeat(1025) }] }] },
  { embeds: [{ description: 'x'.repeat(6001) }] },
]) {
  assert.equal((await json('/discord/receive', {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(invalidPayload),
  })).response.status, 400);
}

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
  fee_amount: null, fee_currency: null, medical_status: 'not_reported', is_huge_rumor: false, is_digest_worthy: true,
  preferred_source: { ...sourceMetadata({ username: index > 14 ? 'someone' : 'David_Ornstein', display_name: 'Mock Source', external_account_id: String(900000000000000000n + BigInt(index)), account_type: 'individual', source_kind: 'journalist', publisher_group_key: index > 14 ? 'reporter:someone' : 'reporter:david-ornstein', is_aggregator: false, seed_reliability: index > 14 ? 0.7 : 0.95 }), display_name: 'Mock Source' },
  sources: [{ post_url: `https://x.com/mock/status/${900000000000000000n + BigInt(index)}` }],
  ...(index === 0 ? {
    fee_amount: 25000000,
    fee_currency: 'EUR',
    add_ons_amount: 5000000,
    add_ons_currency: 'EUR',
    fee_context: {
      profile_snapshot_id: '42', market_value: 20000000,
      market_value_currency: 'EUR', market_value_as_of: '2026-08-27T00:00:00Z',
      stale: false, guaranteed_fee_ratio: 1.25, fee_plus_add_ons_ratio: 1.5,
    },
    probability_status: 'active_scored',
    probability: {
      engine_version: 'probability-v1', normalized_probability: 0.62,
      previous_probability: 0.51, probability_delta: 0.11,
      current_stage: 'advanced', terminal_state: 'open',
      explanation: { primary: { reliability: 0.87 }, corroboration: [{ independence_key: 'reporter:second' }], contradictions: [], competition_adjustment: -0.06 },
    },
  } : {}),
}));
reports.push(...reports.slice(0, 3));
const digest = buildDiscordDigest(reports);
assert.equal(digest.embeds[0].fields.length, 18);
assert.equal(new Set(digest.embeds[0].fields.map((field) => field.name)).size, 18);
const activeField = digest.embeds[0].fields.find((field) => field.name.includes('Mock Player 0'));
assert.match(activeField.value, /Probability: 62% \(▲ \+11\)/);
assert.match(activeField.value, /Stage: Advanced talks/);
assert.match(activeField.value, /Fee: €25m \+ €5m add-ons · Sofascore value €20m \(1\.25x guaranteed, 1\.5x incl\. add-ons, fresh\)/);
assert.doesNotMatch(activeField.value, /Confidence:/);
const discordBeforeNormal = (await json('/state')).body.discordRequests;
const sent = await json('/discord/receive', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(digest) });
assert.equal(sent.response.status, 200);
assert.match(sent.body.id, /^mock-discord-/);

const interrupted = await fetch(`${base}/discord/receive?simulateTerminate=1`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(digest) }).catch(() => null);
assert.equal(interrupted, null);
const recovered = recoverInterruptedDelivery({ status: 'sending' });
assert.equal(recovered.status, 'unknown');
assert.equal(recovered.retryable, false);
assert.equal((await json('/state')).body.discordRequests, discordBeforeNormal + 2);

const entityAliases = await loadEntityAliases(new URL('../../workflow/entity-aliases.json', import.meta.url));
const updateNow = Date.parse('2026-07-30T12:00:00.000Z');
const sentRumor = {
  ...reports[0], player_name: 'Kerim Alajbegovic', current_club_name: 'Bayer 04 Leverkusen', destination_club_name: 'Juventus', fee_amount: 33000000, fee_currency: 'EUR',
};
const confirmation = {
  ...sentRumor, player_name: 'Kerim Alajbegović', current_club_name: 'Bayer Leverkusen', classification: 'official_confirmed', fee_amount: 35000000,
  sent_history: [{ snapshot: sentRumor, sent_at: '2026-07-30T06:00:00.000Z' }],
};
assert.equal(buildDiscordDigest([confirmation], { entityAliases, now: updateNow }).embeds[0].fields.length, 1);
const confirmedUpdate = {
  ...confirmation, fee_amount: 36000000, sent_history: [{ snapshot: confirmation, sent_at: '2026-07-30T11:00:00.000Z' }],
};
assert.equal(buildDiscordDigest([confirmedUpdate], { entityAliases, now: updateNow }).embeds[0].fields.length, 0);
assert.equal(buildDiscordDigest([{ ...confirmedUpdate, classification: 'rejected_failed' }], { entityAliases, now: updateNow }).embeds[0].fields.length, 1);

process.stdout.write('Mock E2E scenarios passed.\n');
