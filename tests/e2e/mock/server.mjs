import { createServer } from 'node:http';

const redisValues = new Map();
const state = {
  rapidRate: 0,
  rapidFail: 0,
  twscrapeCalls: 0,
  qwenCalls: 0,
  sofascoreCalls: 0,
  discordRequests: 0,
  discordPayloads: [],
  redisPipelineRequests: 0,
  redisCommandCount: 0,
};

const validExtraction = {
  transfer_related: true,
  reports: [{
    player_name: 'Mock Player', player_identity_hint: null, current_club_name: 'Mock FC', former_club_name: null, destination_club_name: 'Test United',
    classification: 'advanced_negotiations', move_type: 'permanent', fee_amount: null, fee_currency: null,
    add_ons_amount: null, add_ons_currency: null, release_clause_amount: null, release_clause_currency: null,
    contract_length_months: null, contract_expires_on: null, loan_ends_on: null, has_option_to_buy: null,
    has_obligation_to_buy: null, sell_on_percentage: null, medical_status: 'not_reported', agreement_status: 'not_reported', is_huge_rumor: false, is_digest_worthy: true,
    stage_signal: 'advanced', claim_stance: 'supports', wording_strength: 'reported', club_agreement_state: 'talks', personal_terms_state: 'talks',
    completion_claim: 'none', attribution_kind: 'original', named_originator: null, extraction_confidence: 0.8,
  }],
};

function json(response, status, body, headers = {}) {
  response.writeHead(status, { 'content-type': 'application/json', ...headers });
  response.end(JSON.stringify(body));
}

function clearExpiredRedisValues() {
  const now = Date.now();
  for (const [key, entry] of redisValues) {
    if (entry.expiresAt !== null && entry.expiresAt <= now) redisValues.delete(key);
  }
}

function stateSnapshot() {
  clearExpiredRedisValues();
  return { ...state, redisValues: Object.fromEntries([...redisValues].map(([key, entry]) => [key, entry.value])) };
}

function resetState() {
  Object.assign(state, {
    rapidRate: 0,
    rapidFail: 0,
    twscrapeCalls: 0,
    qwenCalls: 0,
    sofascoreCalls: 0,
    discordRequests: 0,
    discordPayloads: [],
    redisPipelineRequests: 0,
    redisCommandCount: 0,
  });
  redisValues.clear();
}

async function requestBody(request) {
  let body = '';
  for await (const chunk of request) body += chunk;
  return body;
}

function redisPipelineResult(command) {
  if (!Array.isArray(command) || command.length < 2) return { error: 'ERR invalid command' };
  const operation = String(command[0]).toUpperCase();
  const key = String(command[1] ?? '');
  clearExpiredRedisValues();
  if (operation === 'GET' && command.length === 2) return { result: redisValues.get(key)?.value ?? null };
  if (operation !== 'SET' || command.length < 3) return { error: 'ERR unsupported command' };
  const value = String(command[2]);
  let expiresAt = null;
  for (let index = 3; index < command.length; index += 1) {
    if (String(command[index]).toUpperCase() !== 'EX' || !/^\d+$/.test(String(command[index + 1] ?? ''))) return { error: 'ERR invalid expiry' };
    const ttl = Number(command[index + 1]);
    if (!Number.isSafeInteger(ttl) || ttl < 1) return { error: 'ERR invalid expiry' };
    expiresAt = Date.now() + ttl * 1000;
    index += 1;
  }
  redisValues.set(key, { value, expiresAt });
  return { result: 'OK' };
}

function discordPayloadWithinLimits(payload) {
  const embeds = payload?.embeds ?? [];
  if (embeds.length > 10) return false;
  let aggregate = 0;
  const valid = embeds.every((embed) => {
    const fields = embed.fields ?? [];
    const characters = String(embed.title ?? '').length + String(embed.description ?? '').length
      + String(embed.footer?.text ?? '').length
      + fields.reduce((total, field) => total + String(field.name ?? '').length + String(field.value ?? '').length, 0);
    aggregate += characters;
    return fields.length <= 25 && fields.every((field) => (
      String(field.name ?? '').length <= 256
      && String(field.value ?? '').length <= 1024
    ));
  });
  return valid && aggregate <= 6000;
}

function enrichmentItem(item, mode) {
  if (mode === 'all-failure') {
    return {
      item_key: item.item_key,
      status: 'provider_failure',
      resolver_version: 'identity-v9',
      identity: null,
      profile: null,
      statistics: null,
      error: { code: 'fixture_provider_failure', retryable: true },
    };
  }
  if (mode === 'ambiguous') {
    return {
      item_key: item.item_key,
      status: 'ambiguous',
      resolver_version: 'identity-v9',
      identity: null,
      profile: null,
      statistics: null,
      candidates: [
        { provider_player_id: '2544168', canonical_name: 'John Smith', score: 50 },
        { provider_player_id: '2332241', canonical_name: 'John Smith', score: 50 },
      ],
      error: { code: 'identity_margin_too_small', retryable: false },
    };
  }
  const sparse = mode === 'sparse';
  return {
    item_key: item.item_key,
    status: 'fresh',
    resolver_version: 'identity-v9',
    provider_calls: 2,
    identity: {
      provider: 'sofascore',
      provider_player_id: sparse ? '845067' : '826643',
      stable_source_identifier: `sofascore:player:${sparse ? '845067' : '826643'}`,
      score: 100,
      margin: 100,
      resolver_version: 'identity-v9',
    },
    profile: {
      canonical_name: sparse ? 'Nguyễn Quang Hải' : 'Kylian Mbappé',
      current_club: {
        provider_team_id: sparse ? '193616' : '2829',
        name: sparse ? 'Công An Hà Nội' : 'Real Madrid',
      },
      nationality: sparse ? 'Vietnam' : 'France',
      age: sparse ? 29 : 27,
      primary_position: sparse ? 'Midfielder' : 'Forward',
      market_value: sparse ? 435000 : 191000000,
      market_value_currency: 'EUR',
      retrieved_at: '2026-07-30T00:00:00Z',
    },
    statistics: {
      competition: sparse ? 'V-League 1' : 'LaLiga',
      provider_unique_tournament_id: sparse ? '626' : '8',
      season: '2025/26',
      provider_season_id: sparse ? '78589' : '77559',
      season_state: 'latest_completed',
      scope: 'selected_domestic_league_all_clubs',
      appearances: sparse ? 24 : 31,
      starts: sparse ? 24 : 29,
      minutes_played: sparse ? 2160 : 2604,
      minutes_per_game: sparse ? 90 : 84,
      goals: sparse ? 3 : 25,
      expected_goals: sparse ? null : 23.9453,
      assists: sparse ? 6 : 5,
      expected_assists: sparse ? null : 6.2019957,
      average_rating: sparse ? 7.4083 : 7.5613,
      retrieved_at: '2026-07-30T00:00:00Z',
    },
    provenance: {
      profile_cache: 'miss',
      statistics_cache: 'miss',
      raw_payloads: { profile: {}, statistics: {} },
    },
    warnings: [],
  };
}

createServer(async (request, response) => {
  const url = new URL(request.url, 'http://mock');
  if (url.pathname === '/health') return json(response, 200, { ok: true });
  if (url.pathname === '/state') return json(response, 200, stateSnapshot());
  if (url.pathname === '/state/reset') {
    resetState();
    return json(response, 200, stateSnapshot());
  }
  if (url.pathname === '/rapid/rate') {
    state.rapidRate += 1;
    if (state.rapidRate === 1) return json(response, 429, { error: 'rate limited' }, { 'retry-after': '1', 'x-ratelimit-reset': String(Math.ceil(Date.now() / 1000) + 1) });
    return json(response, 200, { data: { entries: [] } });
  }
  if (url.pathname === '/rapid/fail') {
    state.rapidFail += 1;
    return json(response, 503, { error: 'unavailable' });
  }
  if (url.pathname.startsWith('/rapid/user/')) return json(response, 200, { data: { entries: [] } });
  if (url.pathname === '/twscrape/collect') {
    let body = '';
    for await (const chunk of request) body += chunk;
    let payload = {};
    try { payload = JSON.parse(body || '{}'); } catch { return json(response, 400, { error: 'invalid JSON' }); }
    if (!Array.isArray(payload.sources) || payload.limit !== 20) return json(response, 400, { error: 'invalid collection request' });
    state.twscrapeCalls += 1;
    const available = payload.sources[0];
    const unavailable = payload.sources[1] ?? { source_id: 'unavailable', username: 'unavailable', x_user_id: '0' };
    return json(response, 200, {
      posts: available ? [{
        source_id: String(available.source_id), username: String(available.username), x_user_id: String(available.x_user_id),
        external_post_id: '900000000000000201', post_url: `https://x.com/${available.username}/status/900000000000000201`,
        content: 'Mock twscrape transfer report\n\nQuoted post:\nMock quoted transfer report', posted_at: '2026-07-27T00:00:00.000Z', is_quote: true,
        raw_payload: { id: '900000000000000201', id_str: '900000000000000201' },
      }, {
        source_id: String(available.source_id), username: String(available.username), x_user_id: String(available.x_user_id),
        external_post_id: '900000000000000202', post_url: `https://x.com/${available.username}/status/900000000000000202`,
        content: 'Mock stale transfer report', posted_at: '2026-07-26T23:59:59.999Z', is_quote: false,
        raw_payload: { id: '900000000000000202', id_str: '900000000000000202' },
      }, {
        source_id: String(available.source_id), username: String(available.username), x_user_id: String(available.x_user_id),
        external_post_id: '900000000000000203', post_url: `https://x.com/${available.username}/status/900000000000000203`,
        content: 'Mock future transfer report', posted_at: '2026-07-27T06:00:00.001Z', is_quote: false,
        raw_payload: { id: '900000000000000203', id_str: '900000000000000203' },
      }] : [],
      errors: [{
        source_id: String(unavailable.source_id), username: String(unavailable.username), x_user_id: String(unavailable.x_user_id),
        code: 'account_unavailable', message: 'X account unavailable', retryable: true,
      }],
    });
  }
  if (url.pathname === '/upstash/pipeline') {
    state.redisPipelineRequests += 1;
    const body = await requestBody(request);
    const responseMode = url.searchParams.get('response');
    if (responseMode === '500') return json(response, 500, { error: 'mock Redis unavailable' });
    if (responseMode === 'malformed') {
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end('{not json');
      return;
    }
    let commands = [];
    try { commands = JSON.parse(body); } catch { return json(response, 400, { error: 'invalid pipeline JSON' }); }
    if (!Array.isArray(commands)) return json(response, 400, { error: 'pipeline body must be an array' });
    state.redisCommandCount += commands.length;
    return json(response, 200, commands.map(redisPipelineResult));
  }
  if (url.pathname.startsWith('/qwen/')) {
    state.qwenCalls += 1;
    const mode = url.pathname.split('/').at(-1);
    const content = mode === 'malformed' ? '{not json' : mode === 'invalid'
      ? JSON.stringify({ ...validExtraction, unexpected: true })
      : mode === 'women' ? JSON.stringify({ transfer_related: false, reports: [] })
      : JSON.stringify(validExtraction);
    return json(response, 200, { choices: [{ message: { content } }] });
  }
  if (url.pathname === '/v1/enrich') {
    let body = '';
    for await (const chunk of request) body += chunk;
    let payload = {};
    try { payload = JSON.parse(body || '{}'); } catch { return json(response, 400, { error: { code: 'invalid_request' } }); }
    if (!payload.request_id || !Array.isArray(payload.players) || payload.players.length === 0) {
      return json(response, 400, { error: { code: 'invalid_request' } });
    }
    state.sofascoreCalls += 1;
    const mode = payload.request_id.includes('all-failure') ? 'all-failure'
      : payload.request_id.includes('ambiguous') ? 'ambiguous'
      : payload.request_id.includes('sparse') ? 'sparse'
      : payload.request_id.includes('malformed') ? 'malformed'
      : payload.request_id.includes('timeout') ? 'timeout'
      : 'success';
    if (mode === 'timeout') await new Promise((resolve) => setTimeout(resolve, 500));
    if (mode === 'malformed') return json(response, 200, { request_id: payload.request_id, items: null });
    const items = payload.players.map((item) => enrichmentItem(item, mode));
    return json(response, 200, {
      request_id: payload.request_id,
      status: items.every((item) => item.status === 'fresh') ? 'complete' : 'partial',
      items,
      summary: {
        requested: items.length,
        fresh: items.filter((item) => item.status === 'fresh').length,
        failed: items.filter((item) => item.status === 'provider_failure').length,
        deferred: 0,
      },
    });
  }
  if (url.pathname.startsWith('/discord/')) {
    let body = '';
    for await (const chunk of request) body += chunk;
    let payload = {};
    try { payload = JSON.parse(body || '{}'); } catch { return json(response, 400, { error: 'invalid JSON' }); }
    state.discordRequests += 1;
    state.discordPayloads.push(payload);
    if (!discordPayloadWithinLimits(payload)) return json(response, 400, { error: 'Discord limits exceeded' });
    if (url.pathname === '/discord/limited') return json(response, 429, { retry_after: 1 });
    if (url.searchParams.get('simulateTerminate') === '1') {
      response.destroy();
      return;
    }
    return json(response, 200, { id: `mock-discord-${state.discordRequests}` });
  }
  return json(response, 404, { error: 'not found' });
}).listen(18081, '0.0.0.0');
