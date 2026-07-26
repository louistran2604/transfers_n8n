import { createServer } from 'node:http';

const state = { rapidRate: 0, rapidFail: 0, discordRequests: 0, discordPayloads: [] };

const validExtraction = {
  transfer_related: true,
  reports: [{
    player_name: 'Mock Player', player_identity_hint: null, current_club_name: 'Mock FC', destination_club_name: 'Test United',
    classification: 'advanced_negotiations', move_type: 'permanent', fee_amount: null, fee_currency: null,
    add_ons_amount: null, add_ons_currency: null, release_clause_amount: null, release_clause_currency: null,
    contract_length_months: null, contract_expires_on: null, loan_ends_on: null, has_option_to_buy: null,
    has_obligation_to_buy: null, sell_on_percentage: null, medical_status: 'not_reported', agreement_status: 'not_reported', confidence: 0.8,
  }],
};

function json(response, status, body, headers = {}) {
  response.writeHead(status, { 'content-type': 'application/json', ...headers });
  response.end(JSON.stringify(body));
}

function discordPayloadWithinLimits(payload) {
  const embeds = payload?.embeds ?? [];
  if (embeds.length > 10) return false;
  return embeds.every((embed) => {
    const fields = embed.fields ?? [];
    const characters = String(embed.title ?? '').length + String(embed.description ?? '').length
      + fields.reduce((total, field) => total + String(field.name ?? '').length + String(field.value ?? '').length, 0);
    return fields.length <= 25 && characters <= 6000 && fields.every((field) => String(field.value ?? '').length <= 1024);
  });
}

createServer(async (request, response) => {
  const url = new URL(request.url, 'http://mock');
  if (url.pathname === '/health') return json(response, 200, { ok: true });
  if (url.pathname === '/state') return json(response, 200, state);
  if (url.pathname === '/state/reset') {
    Object.assign(state, { rapidRate: 0, rapidFail: 0, discordRequests: 0, discordPayloads: [] });
    return json(response, 200, state);
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
  if (url.pathname.startsWith('/qwen/')) {
    const mode = url.pathname.split('/').at(-1);
    const content = mode === 'malformed' ? '{not json' : mode === 'invalid'
      ? JSON.stringify({ ...validExtraction, unexpected: true })
      : JSON.stringify(validExtraction);
    return json(response, 200, { choices: [{ message: { content } }] });
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
