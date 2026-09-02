import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import {
  buildEnrichmentRequest,
  buildDiscordDigest,
  buildProcessedPostLookupBatches,
  buildProcessedPostSetBatches,
  canonicalizeQwenResponse,
  canonicalizeReport,
  chooseClassification,
  dedupeKey,
  enrichmentUnicodeKey,
  loadEntityAliases,
  loadSourceRegistry,
  materialRevision,
  materialSnapshot,
  mergeReportGroup,
  normalizeEnrichmentResponse,
  propagateConnectedDigestWorthiness,
  normalizeProcessedPostCacheConfig,
  normalizeProcessedPostCacheTtl,
  processedPostCacheKey,
  parseEntityAliases,
  parseSourceRegistry,
  recoverInterruptedDelivery,
  retryDelayMs,
  selectDigestReports,
  shouldRetry,
  sourceMetadata,
  validateQwenResponse,
} from '../../workflow/lib.mjs';

const entityAliases = await loadEntityAliases(new URL('../../workflow/entity-aliases.json', import.meta.url));

const validReport = (overrides = {}) => ({
  player_name: 'Álvaro Test',
  player_identity_hint: null,
  current_club_name: 'Test FC',
  former_club_name: null,
  destination_club_name: 'Destination FC',
  move_effective_on: null,
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
  is_huge_rumor: false,
  is_digest_worthy: true,
  confidence: 0.7,
  ...overrides,
});

const evidenceReport = (overrides = {}) => {
  const { confidence: _confidence, ...report } = validReport();
  return {
    ...report,
    stage_signal: 'talks',
    claim_stance: 'supports',
    wording_strength: 'reported',
    club_agreement_state: 'talks',
    personal_terms_state: 'not_reported',
    completion_claim: 'none',
    attribution_kind: 'original',
    named_originator: null,
    extraction_confidence: 0.7,
    ...overrides,
  };
};

const source = (username, account_type = 'individual') => {
  const lower = username.toLowerCase();
  const isOfficial = ['realmadrid', 'manutd'].includes(lower);
  const seed_reliability = ['david_ornstein', 'fabrizioromano'].includes(lower) ? 0.95 : isOfficial ? 1 : account_type === 'organization' ? 0.8 : 0.7;
  return sourceMetadata({
    username,
    display_name: username,
    external_account_id: '900000000000000001',
    account_type,
    source_kind: isOfficial ? 'club_official' : account_type === 'organization' ? 'publisher' : 'journalist',
    publisher_group_key: `${isOfficial ? 'club' : account_type === 'organization' ? 'publisher' : 'reporter'}:${lower.replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')}`,
    is_aggregator: false,
    seed_reliability,
  });
};

const richEnrichment = (overrides = {}) => ({
  profile: {
    current_club_name: 'Real Madrid',
    nationality: 'France',
    date_of_birth: '1998-12-20',
    age: 27,
    primary_position: 'Forward',
    height_cm: 180,
    preferred_foot: 'Right',
    market_value: 191000000,
    market_value_currency: 'EUR',
    retrieved_at: '2026-07-30T00:00:00Z',
    stale: false,
  },
  statistics: {
    competition_name: 'LaLiga',
    season_label: '2025/26',
    season_state: 'latest_completed',
    scope: 'selected_domestic_league_all_clubs',
    appearances: 31,
    starts: 29,
    minutes_played: 2604,
    minutes_per_appearance: 84,
    goals: 25,
    expected_goals: 23.9453,
    assists: 5,
    expected_assists: 6.2019957,
    average_rating: 7.5612903225806,
    yellow_cards: 3,
    red_cards: 0,
    goalkeeper_clean_sheets: null,
    goalkeeper_saves: null,
    retrieved_at: '2026-07-30T00:00:00Z',
    stale: false,
  },
  ...overrides,
});

const discordCharacterCount = (embed) => (
  embed.title.length
  + embed.footer.text.length
  + embed.fields.reduce((total, field) => total + field.name.length + field.value.length, 0)
);

test('processed-post cache configuration defaults off and normalizes active settings', () => {
  assert.deepEqual(normalizeProcessedPostCacheConfig(), {
    mode: 'off', restUrl: '', restToken: '', postTtlSeconds: 86400,
  });
  assert.deepEqual(normalizeProcessedPostCacheConfig({
    mode: ' ACTIVE ', restUrl: 'https://example.upstash.io/', restToken: ' read-write-token ', postTtlSeconds: '3600',
  }), {
    mode: 'active', restUrl: 'https://example.upstash.io', restToken: 'read-write-token', postTtlSeconds: 3600,
  });
});

test('processed-post cache configuration fails closed to off for missing or invalid active settings', () => {
  for (const config of [
    { mode: 'active' },
    { mode: 'active', restUrl: 'not a URL', restToken: 'token' },
    { mode: 'active', restUrl: 'http://example.upstash.io', restToken: 'token' },
    { mode: 'active', restUrl: 'https://example.upstash.io', restToken: '' },
    { mode: 'active', restUrl: 'https://example.upstash.io', restToken: 'token', postTtlSeconds: 0 },
    { mode: 'active', restUrl: 'https://example.upstash.io', restToken: 'token', postTtlSeconds: '1.5' },
  ]) assert.deepEqual(normalizeProcessedPostCacheConfig(config), {
    mode: 'off', restUrl: '', restToken: '', postTtlSeconds: 86400,
  });
  assert.equal(normalizeProcessedPostCacheConfig({ mode: 'unknown' }).mode, 'off');
});

test('processed-post cache TTL accepts bounded positive integer seconds only', () => {
  assert.equal(normalizeProcessedPostCacheTtl(1), 1);
  assert.equal(normalizeProcessedPostCacheTtl('86400'), 86400);
  for (const value of [null, '', '1.5', 0, -1, Number.NaN, Number.POSITIVE_INFINITY, 31_536_001, Number.MAX_SAFE_INTEGER]) {
    assert.equal(normalizeProcessedPostCacheTtl(value), null, String(value));
  }
});

test('processed-post cache keys validate decimal X IDs and preserve the namespace', () => {
  assert.equal(processedPostCacheKey('900000000000000001'), 'ftm:v1:processed-post:x:900000000000000001');
  assert.equal(processedPostCacheKey(42), 'ftm:v1:processed-post:x:42');
  for (const value of ['', '  ', 'abc', '1/2', null, undefined]) {
    assert.throws(() => processedPostCacheKey(value), /external post ID/i);
  }
});

test('processed-post lookup batches deduplicate IDs and stay bounded', () => {
  assert.deepEqual(buildProcessedPostLookupBatches(['1', '2', '1', '3'], 2), [
    [['GET', 'ftm:v1:processed-post:x:1'], ['GET', 'ftm:v1:processed-post:x:2']],
    [['GET', 'ftm:v1:processed-post:x:3']],
  ]);
  assert.deepEqual(buildProcessedPostLookupBatches([], 2), []);
  assert.throws(() => buildProcessedPostLookupBatches(['1'], 0), /batch size/i);
});

test('processed-post SET batches deduplicate IDs and include terminal state and EX TTL', () => {
  assert.deepEqual(buildProcessedPostSetBatches([
    { externalPostId: '1', state: 'ignored' },
    { externalPostId: '2', state: 'merged' },
    { externalPostId: '1', state: 'ignored' },
  ], 900, 2), [
    [['SET', 'ftm:v1:processed-post:x:1', 'ignored', 'EX', '900'], ['SET', 'ftm:v1:processed-post:x:2', 'merged', 'EX', '900']],
  ]);
  assert.deepEqual(buildProcessedPostSetBatches([], 900), []);
  assert.throws(() => buildProcessedPostSetBatches([{ externalPostId: '1', state: 'pending' }]), /terminal state/i);
  assert.throws(() => buildProcessedPostSetBatches([{ externalPostId: '1', state: 'ignored' }], 0), /TTL/i);
});

test('source registry exposes valid explicit metadata for all 78 unique decimal IDs', async () => {
  const registry = await loadSourceRegistry(new URL('../../docs/journalist_list.md', import.meta.url));
  assert.equal(registry.length, 78);
  assert.equal(new Set(registry.map((account) => account.external_account_id)).size, 78);
  assert.ok(registry.every((account) => /^\d+$/.test(account.external_account_id)));
  assert.ok(registry.every((account) => ['journalist', 'publisher', 'club_official', 'league_official', 'aggregator'].includes(account.source_kind)));
  assert.ok(registry.every((account) => /^[a-z0-9]+(?::[a-z0-9]+(?:-[a-z0-9]+)*)?$/.test(account.publisher_group_key)));
  assert.ok(registry.every((account) => typeof account.is_aggregator === 'boolean'));
  assert.ok(registry.every((account) => Number.isFinite(account.seed_reliability) && account.seed_reliability >= 0 && account.seed_reliability <= 1));
  const harpur = registry.find((account) => account.username === 'charlotteharpur');
  assert.equal(harpur.external_account_id, '922928582866980864');
  assert.equal(typeof harpur.external_account_id, 'string');
  const expected = {
    realmadrid: ['club_official', 'club:real-madrid', 1, false, true, 1],
    David_Ornstein: ['journalist', 'reporter:david-ornstein', 0.95, false, false, 2],
    AdamCrafton_: ['journalist', 'reporter:adamcrafton', 0.7, false, false, 4],
    BBCSport: ['publisher', 'publisher:bbc-sport', 0.8, false, false, 3],
  };
  for (const [username, values] of Object.entries(expected)) {
    const account = registry.find((candidate) => candidate.username === username);
    assert.deepEqual([account.source_kind, account.publisher_group_key, account.seed_reliability, account.is_aggregator, account.is_official, account.priority_rank], values);
    assert.equal(account.reliability_score, account.seed_reliability);
  }
});

test('source metadata rejects missing, malformed, and inconsistent explicit values', async () => {
  const markdown = await readFile(new URL('../../docs/journalist_list.md', import.meta.url), 'utf8');
  const missing = markdown.replace('| journalist | `reporter:adamcrafton` | false | 0.7000 |', '|  | `reporter:adamcrafton` | false | 0.7000 |');
  const malformed = markdown.replace('| journalist | `reporter:adamcrafton` | false | 0.7000 |', '| journalist | `Reporter:Adam Crafton` | false | 1.2000 |');
  const invalidSeed = markdown.replace('| journalist | `reporter:adamcrafton` | false | 0.7000 |', '| journalist | `reporter:adamcrafton` | false | NaN |');
  const invalidBoolean = markdown.replace('| journalist | `reporter:adamcrafton` | false | 0.7000 |', '| journalist | `reporter:adamcrafton` | no | 0.7000 |');
  const inconsistent = markdown.replace('| journalist | `reporter:adamcrafton` | false | 0.7000 |', '| aggregator | `reporter:adamcrafton` | false | 0.7000 |');
  assert.throws(() => parseSourceRegistry(missing), /source kind/i);
  assert.throws(() => parseSourceRegistry(malformed), /publisher group|seed reliability/i);
  assert.throws(() => parseSourceRegistry(invalidSeed), /seed reliability/i);
  assert.throws(() => parseSourceRegistry(invalidBoolean), /aggregator/i);
  assert.throws(() => parseSourceRegistry(inconsistent), /aggregator/i);
});

test('generated source upserts persist explicit reliability and independence metadata', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const insertClause = `INSERT INTO source_accounts (
  platform, external_account_id, username, display_name, account_type,
  is_official, priority_rank, reliability_score, seed_reliability,
  publisher_group_key, source_kind, is_aggregator
) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12)`;
  const updateClause = `seed_reliability = EXCLUDED.seed_reliability,
    publisher_group_key = EXCLUDED.publisher_group_key,
    source_kind = EXCLUDED.source_kind,
    is_aggregator = EXCLUDED.is_aggregator`;
  const returningClause = `RETURNING id::text AS source_account_id, platform, external_account_id, username,
  display_name, account_type, is_official, priority_rank, reliability_score,
  seed_reliability, publisher_group_key, source_kind, is_aggregator;`;
  for (const name of ['Upsert source accounts', 'Upsert sample source account']) {
    const query = workflow.nodes.find((node) => node.name === name).parameters.query;
    assert.ok(query.includes(insertClause));
    assert.ok(query.includes(updateClause));
    assert.ok(query.includes(returningClause));
  }
  const expectedParams = ['x', '242077026', 'AdamCrafton_', 'Adam Crafton', 'individual', false, 4, 0.7, 0.7, 'reporter:adamcrafton', 'journalist', false];
  for (const name of ['Load generated sources', 'Load sample source']) {
    const output = Function(workflow.nodes.find((node) => node.name === name).parameters.jsCode)();
    assert.deepEqual(output[0].json.params, expectedParams);
  }
});

test('strict Qwen validation accepts the exact evidence contract and rejects unknown scoring fields', () => {
  const accepted = { transfer_related: true, reports: [evidenceReport()] };
  assert.equal(validateQwenResponse(accepted).valid, true);
  assert.equal(validateQwenResponse({ ...accepted, source_url: 'https://bad.example' }).valid, false);
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ fee_currency: 'eur' })] }).valid, false);
  for (const field of ['percentage', 'transfer_probability', 'probability_contribution', 'reliability_score', 'independent_source_count', 'explanation']) {
    assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ [field]: 1 })] }).valid, false, field);
  }
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ confidence: 0.9 })] }).valid, false);
  const missing = evidenceReport();
  delete missing.player_name;
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [missing] }).valid, false);
});

test('Qwen evidence enums cover stages, gates, completion wording, and attribution', () => {
  const enumCases = {
    stage_signal: ['link', 'interest', 'talks', 'advanced', 'agreed', 'done', 'setback', 'collapsed', 'official_wording', 'not_reported'],
    claim_stance: ['supports', 'contradicts', 'neutral'],
    wording_strength: ['hedged', 'reported', 'direct', 'definitive'],
    club_agreement_state: ['not_reported', 'not_applicable', 'talks', 'agreed', 'rejected', 'collapsed'],
    personal_terms_state: ['not_reported', 'talks', 'agreed', 'rejected'],
    completion_claim: ['none', 'reporter_done', 'official_announcement'],
    attribution_kind: ['original', 'cites_named_source', 'aggregation', 'unknown'],
  };
  for (const [field, values] of Object.entries(enumCases)) {
    for (const value of values) assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ [field]: value })] }).valid, true, `${field}=${value}`);
    assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ [field]: 'invalid' })] }).valid, false, field);
  }

  for (const report of [
    evidenceReport({ stage_signal: 'setback', club_agreement_state: 'rejected' }),
    evidenceReport({ stage_signal: 'collapsed', club_agreement_state: 'collapsed', claim_stance: 'contradicts' }),
    evidenceReport({ stage_signal: 'agreed', club_agreement_state: 'agreed', personal_terms_state: 'not_reported' }),
    evidenceReport({ stage_signal: 'agreed', club_agreement_state: 'agreed', personal_terms_state: 'agreed' }),
    evidenceReport({ stage_signal: 'done', completion_claim: 'reporter_done' }),
    evidenceReport({ stage_signal: 'official_wording', completion_claim: 'official_announcement' }),
    evidenceReport({ attribution_kind: 'cites_named_source', named_originator: 'David Ornstein' }),
    evidenceReport({ attribution_kind: 'aggregation' }),
  ]) assert.equal(validateQwenResponse({ transfer_related: true, reports: [report] }).valid, true);

  assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ named_originator: '' })] }).valid, false);
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ named_originator: 42 })] }).valid, false);
  for (const extraction_confidence of [-0.01, 1.01, Number.NaN, Number.POSITIVE_INFINITY]) {
    assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ extraction_confidence })] }).valid, false);
  }
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [
    evidenceReport({ destination_club_name: 'Club A', stage_signal: 'link' }),
    evidenceReport({ destination_club_name: 'Club B', stage_signal: 'interest' }),
  ] }).valid, true);
});

test('reusable Qwen compatibility maps the exact legacy confidence report once', () => {
  const legacy = { transfer_related: true, reports: [validReport({ confidence: 0.83 })] };
  assert.equal(validateQwenResponse(legacy).valid, true);
  const canonical = canonicalizeQwenResponse(legacy);
  assert.equal(canonical.reports[0].extraction_confidence, 0.83);
  assert.equal('confidence' in canonical.reports[0], false);
  assert.equal(canonical.reports[0].stage_signal, 'not_reported');
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [{ ...evidenceReport(), confidence: 0.5 }] }).valid, false);
});

test('Qwen contract keeps explicit former senior club separate from omitted current club', async () => {
  const report = evidenceReport({
    player_name: 'Endrick',
    current_club_name: null,
    former_club_name: 'Palmeiras',
    destination_club_name: 'Chelsea',
  });
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [report] }).valid, true);
  const missing = { ...report };
  delete missing.former_club_name;
  assert.equal(validateQwenResponse({ transfer_related: true, reports: [missing] }).valid, false);
  const prompt = await readFile(new URL('../../workflow/qwen-system-prompt.md', import.meta.url), 'utf8');
  assert.match(prompt, /former\/ex-player/);
  assert.match(prompt, /Academy, birthplace, nationality, and origin-only wording must not populate/);
  assert.match(prompt, /same player is linked to multiple distinct destination clubs/);
  assert.match(prompt, /move_effective_on/);
  assert.match(prompt, /completed-market recap/);
  const schema = JSON.parse(await readFile(new URL('../../workflow/qwen-response-schema.json', import.meta.url), 'utf8'));
  assert.ok(schema.properties.reports.items.required.includes('former_club_name'));
  assert.ok(schema.properties.reports.items.required.includes('extraction_confidence'));
  assert.ok(schema.properties.reports.items.required.includes('move_effective_on'));
  assert.equal(schema.properties.reports.items.properties.move_effective_on.pattern, '^[0-9]{4}-(0[1-9]|1[0-2])(-[0-9]{2})?$');
  assert.equal(schema.properties.reports.items.required.includes('confidence'), false);
});

test('Qwen contract accepts month-precision effective move dates and rejects malformed dates', () => {
  for (const move_effective_on of ['2027-06', '2027-06-30', null]) {
    assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ move_effective_on })] }).valid, true, move_effective_on);
  }
  for (const move_effective_on of ['2027-6', '2027-13', '2027-00', '2027-06-1', 'June 2027']) {
    assert.equal(validateQwenResponse({ transfer_related: true, reports: [evidenceReport({ move_effective_on })] }).valid, false, move_effective_on);
  }
});

test('connected future permanent and loan reports inherit digest worthiness', () => {
  const connected = [
    evidenceReport({
      player_name: 'Honest Ahanor', current_club_name: 'Atalanta', destination_club_name: 'Chelsea',
      move_type: 'permanent', classification: 'official_confirmed', move_effective_on: '2027-06', is_digest_worthy: true,
      raw_post_id: '99', posted_at: '2026-09-01T00:00:00.000Z',
    }),
    evidenceReport({
      player_name: 'Honest Ahanor', current_club_name: 'Atalanta', destination_club_name: 'Crystal Palace',
      move_type: 'loan', classification: 'loan', is_digest_worthy: false,
      raw_post_id: '99', posted_at: '2026-09-01T00:00:00.000Z',
    }),
  ];
  const propagated = propagateConnectedDigestWorthiness(connected, entityAliases);
  assert.equal(propagated[1].is_digest_worthy, true);

  const unrelated = propagateConnectedDigestWorthiness([
    connected[0],
    { ...connected[1], destination_club_name: 'Benfica', move_type: 'permanent', classification: 'rumor' },
  ], entityAliases);
  assert.equal(unrelated[1].is_digest_worthy, false);
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
  assert.equal(materialRevision(first.content_sha256, { ...merged, enrichment: { statistics: { goals: 99 } } }).changed, false);
  assert.equal(materialRevision(first.content_sha256, { ...merged, is_digest_worthy: !merged.is_digest_worthy }).changed, false);
  assert.equal(materialRevision(first.content_sha256, { ...merged, fee_amount: 50000000 }).changed, true);
  assert.equal(dedupeKey(merged), 'alvaro-test|test-fc|destination-fc');
  assert.equal(dedupeKey({ ...merged, player_identity_hint: 'Test FC' }), 'alvaro-test|test-fc|destination-fc');
  assert.equal(chooseClassification(['rumor', 'loan', 'contract_renewal']), 'contract_renewal');
});

test('merge persists former club and NFKC reported-name key without inventing current club', () => {
  const merged = mergeReportGroup([{
    ...validReport({ player_name: 'Ｅndrick—Félipé', current_club_name: null, former_club_name: 'Palmeiras' }),
    source: source('someone'), raw_post_id: '1', post_url: 'https://example.test/1', posted_at: '2026-08-09T00:00:00Z',
  }], entityAliases);
  assert.equal(merged.current_club_name, null);
  assert.equal(merged.former_club_name, 'Palmeiras');
  assert.equal(merged.normalized_data.former_club_name, 'Palmeiras');
  assert.equal(merged.normalized_data.reported_name_key, 'endrick félipé');
  assert.equal(merged.normalized_data.current_club_key, null);
  assert.equal(merged.normalized_data.destination_club_key, 'destination fc');
  assert.equal(materialSnapshot(merged).current_club_name, null);
});

test('entity aliases canonicalize player and club variants without merging siblings', () => {
  const koloMuani = validReport({ player_name: 'Kolo Muani', current_club_name: 'PSG', destination_club_name: 'Man Utd' });
  assert.equal(dedupeKey(koloMuani, entityAliases), 'randal-kolo-muani|paris-saint-germain|manchester-united');
  assert.equal(dedupeKey({ ...koloMuani, player_name: 'Randal Kolo Muani', current_club_name: 'Paris Saint-Germain', destination_club_name: 'Manchester United' }, entityAliases), dedupeKey(koloMuani, entityAliases));
  assert.notEqual(dedupeKey({ ...koloMuani, player_name: 'Kylian Mbappé' }, entityAliases), dedupeKey({ ...koloMuani, player_name: 'Ethan Mbappé' }, entityAliases));
  assert.throws(() => parseEntityAliases({
    clubs: [
      { canonical: 'Club A', aliases: ['Shared Club'] },
      { canonical: 'Club B', aliases: ['Shared Club'] },
    ],
    players: [],
    sibling_groups: [],
    common_surnames: [],
  }), /Conflicting club alias/);
  assert.throws(() => parseEntityAliases({
    clubs: [{ canonical: 'Napoli', aliases: [] }],
    players: [{ canonical: 'Romelu Lukaku', aliases: ['Lukaku'], current_clubs: ['Roma'] }],
    sibling_groups: [],
    common_surnames: [],
  }), /Unknown player alias club/);
  assert.throws(() => parseEntityAliases({
    clubs: [{ canonical: 'Napoli', aliases: ['SSC Napoli'] }],
    players: [
      { canonical: 'Romelu Lukaku', aliases: ['Lukaku'], current_clubs: ['Napoli'] },
      { canonical: 'Other Lukaku', aliases: ['Lukaku'], current_clubs: ['SSC Napoli'] },
    ],
    sibling_groups: [],
    common_surnames: [],
  }), /Conflicting player alias scope/);
  assert.throws(() => parseEntityAliases({
    clubs: [], players: [], sibling_groups: [], common_surnames: [],
    enrichment_player_aliases: [{ reported: 'Lukaku', canonical: 'Romelu Lukaku', current_clubs: ['Napoli'] }],
  }), /has been merged into players/);
  assert.throws(() => parseEntityAliases({
    clubs: [], players: [], sibling_groups: [], common_surnames: ['Rodríguez'],
  }), /Invalid common surname/);
});

test('enrichment grouping uses provider ID or Unicode name and club context, never placeholder player ID', () => {
  assert.equal(enrichmentUnicodeKey('  Kylian—MBAPPÉ  '), 'kylian mbappé');
  const base = {
    reported_player_name: 'Kylian Mbappé',
    current_club_name: 'Real Madrid',
    destination_club_name: 'Liverpool',
    classification: 'rumor',
    move_type: 'permanent',
    aliases: [],
    identity_overrides: [],
    profile_fresh_until: null,
    statistics_fresh_until: null,
    team_mapping_fresh: false,
    season_mapping_fresh: false,
  };
  const grouped = buildEnrichmentRequest([
    { ...base, transfer_report_id: '10', placeholder_player_id: '100', provider_player_id: '826643' },
    { ...base, transfer_report_id: '11', placeholder_player_id: '999', provider_player_id: '826643' },
    { ...base, transfer_report_id: '12', placeholder_player_id: '100', provider_player_id: null },
  ], { mode: 'shadow', requestId: 'sofascore:1', now: 0 });
  assert.equal(grouped.refreshRequired, true);
  assert.deepEqual(grouped.request.players.map((player) => player.item_key), [
    'provider:826643',
    'name:kylian mbappé|club:real madrid',
  ]);
  assert.deepEqual(grouped.request.players[0].report_ids, ['10', '11']);
  assert.equal(grouped.request.players[0].current_club_name, 'Real Madrid');
  assert.equal(grouped.request.players[0].allow_exact_name_without_club, true);
  assert.equal(grouped.request.players[0].completed_move, false);
  assert.equal(grouped.request.players[1].current_club_name, 'Real Madrid');
  assert.equal(buildEnrichmentRequest([base], { mode: 'invalid', requestId: 'x' }).request, null);
});

test('enrichment grouping canonicalizes configured player aliases', () => {
  const context = (transferReportId, reportedPlayerName) => ({
    transfer_report_id: transferReportId,
    reported_player_name: reportedPlayerName,
    current_club_name: 'Manchester City',
    destination_club_name: 'Real Madrid',
    classification: 'rumor',
    move_type: 'permanent',
    aliases: [],
    identity_overrides: [],
  });
  for (const names of [['Rodri', 'Rodri Hernandez'], ['Akilouche', 'Maghnes Akliouche']]) {
    const grouped = buildEnrichmentRequest([
      context('10', names[0]),
      context('11', names[1]),
    ], { mode: 'shadow', requestId: 'sofascore:aliases', now: 0, entityAliases });
    assert.equal(grouped.request.players.length, 1);
    assert.deepEqual(grouped.request.players[0].report_ids, ['10', '11']);
  }
});

test('scoped enrichment aliases rewrite only matching current-club requests', () => {
  const context = (id, currentClub) => ({
    transfer_report_id: id,
    reported_player_name: 'Udogie',
    current_club_name: currentClub,
    destination_club_name: 'Other',
    classification: 'rumor',
    move_type: 'permanent',
    aliases: [],
    identity_overrides: [],
  });
  assert.equal(canonicalizeReport({ player_name: 'Udogie' }, entityAliases).player_name, 'Udogie');
  const matching = buildEnrichmentRequest([context('31', 'Tottenham')], { mode: 'active', requestId: 'matching-club', entityAliases }).request.players[0];
  assert.equal(matching.reported_name, 'Destiny Udogie');
  assert.deepEqual(matching.aliases, ['Udogie']);
  assert.equal(matching.current_club_name, 'Tottenham Hotspur');
  const unrelated = buildEnrichmentRequest([context('32', 'Roma')], { mode: 'active', requestId: 'roma', entityAliases }).request.players[0];
  assert.equal(unrelated.reported_name, 'Udogie');
  assert.deepEqual(unrelated.aliases, []);
});

test('generated enrichment request preserves the current-club discriminator', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const context = {
    transfer_report_id: '10',
    reported_player_name: 'Kylian Mbappé',
    current_club_name: 'Real Madrid',
    destination_club_name: 'Liverpool',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
    team_mapping_fresh: false,
    season_mapping_fresh: false,
  };
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const output = await runRequest({ all: () => [{ json: context }] }, (name) => {
    assert.equal(name, 'Prepare enrichment batch query');
    return { first: () => ({ json: { mode: 'shadow', workflow_run_id: '1' } }) };
  });
  const player = output[0].json.request.players[0];
  assert.equal(player.item_key, 'name:kylian mbappé|club:real madrid');
  assert.equal(player.current_club_name, 'Real Madrid');
  assert.deepEqual(player.report_ids, ['10']);
});

test('generated enrichment request canonicalizes configured player aliases', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const context = (transferReportId, reportedPlayerName) => ({ json: {
    transfer_report_id: transferReportId,
    reported_player_name: reportedPlayerName,
    current_club_name: 'Manchester City',
    destination_club_name: 'Real Madrid',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
  } });
  for (const names of [['Rodri', 'Rodri Hernandez'], ['Akilouche', 'Maghnes Akliouche']]) {
    const output = await runRequest({ all: () => [context('10', names[0]), context('11', names[1])] }, () => ({
      first: () => ({ json: { mode: 'shadow', workflow_run_id: '1' } }),
    }));
    assert.equal(output[0].json.request.players.length, 1);
    assert.deepEqual(output[0].json.request.players[0].report_ids, ['10', '11']);
  }
});

test('surname-only enrichment opt-in is limited to non-common surnames', async () => {
  const context = (reportedPlayerName) => ({
    transfer_report_id: '10',
    reported_player_name: reportedPlayerName,
    current_club_name: 'Chelsea',
    destination_club_name: 'Roma',
    classification: 'advanced_negotiations',
    move_type: 'loan',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
  });
  const gittens = buildEnrichmentRequest([context('Gittens')], {
    mode: 'active', requestId: 'surname', entityAliases,
  }).request.players[0];
  assert.equal(gittens.allow_surname_only_match, true);

  const smith = buildEnrichmentRequest([context('Smith')], {
    mode: 'active', requestId: 'common-surname', entityAliases,
  }).request.players[0];
  assert.equal(smith.allow_surname_only_match, false);

  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const output = await runRequest({ all: () => [{ json: context('Gittens') }] }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  assert.equal(output[0].json.request.players[0].allow_surname_only_match, true);
});

test('generated scoped enrichment alias rewrites only the matching current club', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const context = (id, club) => ({ json: {
    transfer_report_id: id, reported_player_name: 'Udogie', current_club_name: club,
    destination_club_name: 'Other', classification: 'rumor', move_type: 'permanent',
    provider_player_id: null, aliases: [], identity_overrides: [],
  } });
  const execute = (club) => runRequest({ all: () => [context('33', club)] }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  const matching = (await execute('Tottenham'))[0].json.request.players[0];
  assert.equal(matching.reported_name, 'Destiny Udogie');
  assert.deepEqual(matching.aliases, ['Udogie']);
  const roma = (await execute('Roma'))[0].json.request.players[0];
  assert.equal(roma.reported_name, 'Udogie');
  assert.deepEqual(roma.aliases, []);
});

test('equivalent alias cooldown suppresses the entire canonical enrichment group', async () => {
  const now = Date.parse('2026-07-30T12:00:00Z');
  const context = (transferReportId, reportedPlayerName, overrides = {}) => ({
    transfer_report_id: transferReportId,
    reported_player_name: reportedPlayerName,
    current_club_name: 'Manchester City',
    destination_club_name: 'Real Madrid',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
    ...overrides,
  });
  const contexts = [
    context('10', 'Rodri'),
    context('11', 'Rodri Hernandez', { latest_attempt_status: 'ambiguous', latest_attempt_started_at: '2026-07-30T11:00:00Z' }),
  ];
  assert.equal(buildEnrichmentRequest(contexts, { mode: 'active', requestId: 'cooldown', now, entityAliases }).request, null);
  const activeOverride = { action: 'resolve', provider_player_id: '37292', active: true };
  const recoveredContexts = [{ ...contexts[0], identity_overrides: [activeOverride] }, contexts[1]];
  const recovered = buildEnrichmentRequest(recoveredContexts, { mode: 'active', requestId: 'recovered', now, entityAliases });
  assert.deepEqual(recovered.request.players[0].report_ids, ['10']);
  assert.equal(recovered.request.players[0].item_key, 'name:rodri hernández|club:manchester city|report:10');
  assert.deepEqual(recovered.request.players[0].identity_overrides, [activeOverride]);
  const activeReject = { action: 'reject', provider_player_id: '37293', active: true };
  const rejectedCandidateContexts = [{ ...contexts[0], identity_overrides: [activeReject] }, contexts[1]];
  assert.deepEqual(
    buildEnrichmentRequest(rejectedCandidateContexts, { mode: 'active', requestId: 'rejected-candidate', now, entityAliases }).request.players[0].identity_overrides,
    [activeReject],
  );
  const activeRejectAll = { action: 'reject_all', active: true };
  const rejectedAll = buildEnrichmentRequest([
    { ...contexts[0], identity_overrides: [activeRejectAll] }, contexts[1],
  ], { mode: 'active', requestId: 'rejected-all', now, entityAliases });
  assert.deepEqual(rejectedAll.request.players[0].report_ids, ['10']);
  assert.equal(rejectedAll.request.players[0].item_key, 'name:rodri hernández|club:manchester city|report:10');
  assert.equal(buildEnrichmentRequest([
    { ...contexts[0], identity_overrides: [activeOverride], latest_attempt_next_retry_at: '2026-07-30T13:00:00Z' },
    contexts[1],
  ], { mode: 'active', requestId: 'hard-backoff', now, entityAliases }).request, null);

  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', 'const Date = class extends globalThis.Date { static now() { return ' + now + '; } };\n' + requestNode.parameters.jsCode);
  const generated = await runRequest({ all: () => contexts.map((json) => ({ json })) }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  assert.equal(generated[0].json.request, null);
  const generatedRecovered = await runRequest({ all: () => recoveredContexts.map((json) => ({ json })) }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  assert.deepEqual(generatedRecovered[0].json.request.players[0].report_ids, ['10']);
  assert.deepEqual(generatedRecovered[0].json.request.players[0].identity_overrides, [activeOverride]);
  const generatedRejectedCandidate = await runRequest({ all: () => rejectedCandidateContexts.map((json) => ({ json })) }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  assert.deepEqual(generatedRejectedCandidate[0].json.request.players[0].identity_overrides, [activeReject]);
});

test('canonical club aliases produce an order-independent enrichment payload', async () => {
  const context = (transferReportId, currentClubName) => ({
    transfer_report_id: transferReportId,
    reported_player_name: 'Kylian Mbappé',
    current_club_name: currentClubName,
    destination_club_name: 'Liverpool',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
  });
  const orders = [
    [context('10', 'PSG'), context('11', 'Paris Saint-Germain')],
    [context('11', 'Paris Saint-Germain'), context('10', 'PSG')],
  ];
  for (const contexts of orders) {
    const player = buildEnrichmentRequest(contexts, { mode: 'active', requestId: 'club', entityAliases }).request.players[0];
    assert.equal(player.current_club_name, 'Paris Saint-Germain');
    assert.equal(player.request_context.current_club_key, 'paris saint germain');
  }

  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  for (const contexts of orders) {
    const output = await runRequest({ all: () => contexts.map((json) => ({ json })) }, () => ({
      first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
    }));
    assert.equal(output[0].json.request.players[0].current_club_name, 'Paris Saint-Germain');
    assert.equal(output[0].json.request.players[0].request_context.current_club_key, 'paris saint germain');
  }
});

test('enrichment transports curated club variants and every named destination', () => {
  const base = {
    transfer_report_id: '20',
    reported_player_name: 'Test Player',
    current_club_name: 'SSC Napoli',
    destination_club_name: 'Olympique de Marseille',
    classification: 'advanced_negotiations',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
  };
  const rumor = buildEnrichmentRequest([base], { mode: 'active', requestId: 'rumor-clubs', entityAliases }).request.players[0];
  assert.equal(rumor.current_club_name, 'Napoli');
  assert.deepEqual(rumor.current_club_aliases, ['Napoli', 'SSC Napoli', 'sscnapoli']);
  assert.equal(rumor.destination_club_name, 'Marseille');
  assert.deepEqual(rumor.destination_club_aliases, ['Marseille', 'Olympique de Marseille']);

  for (const overrides of [
    { classification: 'official_confirmed' },
    { classification: 'rumor', move_type: 'loan' },
    { classification: 'rejected_failed' },
  ]) {
    const eligible = buildEnrichmentRequest([{ ...base, ...overrides }], { mode: 'active', requestId: 'eligible-clubs', entityAliases }).request.players[0];
    assert.equal(eligible.destination_club_name, 'Marseille');
    assert.deepEqual(eligible.destination_club_aliases, ['Marseille', 'Olympique de Marseille']);
  }
});

test('curated club equivalence is exact in source and generated requests', async () => {
  const context = {
    transfer_report_id: '26',
    reported_player_name: 'Test Player',
    current_club_name: 'Royale Union Saint-Gilloise',
    destination_club_name: 'Other',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
  };
  const sourcePlayer = buildEnrichmentRequest([context], {
    mode: 'active', requestId: 'curated-club-source', entityAliases,
  }).request.players[0];
  assert.equal(sourcePlayer.current_club_name, 'Union Saint-Gilloise');
  assert.deepEqual(sourcePlayer.current_club_aliases, ['Union Saint-Gilloise', 'Royale Union Saint-Gilloise']);

  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const generated = await runRequest({ all: () => [{ json: context }] }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  const generatedPlayer = generated[0].json.request.players[0];
  assert.equal(generatedPlayer.current_club_name, 'Union Saint-Gilloise');
  assert.deepEqual(generatedPlayer.current_club_aliases, ['Union Saint-Gilloise', 'Royale Union Saint-Gilloise']);
});

test('Rodrigo Mora source and generated requests carry canonical Porto aliases in loader order', async () => {
  const context = {
    transfer_report_id: '1410240',
    reported_player_name: 'Rodrigo Mora',
    current_club_name: 'FC Porto',
    destination_club_name: 'Other',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
  };
  const player = buildEnrichmentRequest([context], {
    mode: 'active', requestId: 'rodrigo-source', entityAliases,
  }).request.players[0];
  assert.equal(player.current_club_name, 'Porto');
  assert.deepEqual(player.current_club_aliases, ['Porto', 'FC Porto']);

  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const generated = await runRequest({ all: () => [{ json: context }] }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  const generatedPlayer = generated[0].json.request.players[0];
  assert.equal(generatedPlayer.current_club_name, 'Porto');
  assert.deepEqual(generatedPlayer.current_club_aliases, ['Porto', 'FC Porto']);
});

test('unrelated duplicate remains unresolved and excluded by the ambiguity cooldown', () => {
  const player = buildEnrichmentRequest([{
    transfer_report_id: '1410241',
    reported_player_name: 'John Smith',
    current_club_name: 'Unrelated FC',
    destination_club_name: 'Other',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
    latest_attempt_status: 'ambiguous',
    latest_attempt_started_at: '2026-07-30T11:00:00Z',
  }], {
    mode: 'active', requestId: 'unrelated-duplicate', now: Date.parse('2026-07-30T12:00:00Z'), entityAliases,
  });
  assert.equal(player.request, null);
  assert.equal(player.refreshRequired, false);
});

test('former club alone creates a bounded enrichment identity request', () => {
  const player = buildEnrichmentRequest([{
    transfer_report_id: '24',
    reported_player_name: 'Endrick',
    current_club_name: null,
    former_club_name: 'Palmeiras',
    destination_club_name: 'Chelsea',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
  }], { mode: 'active', requestId: 'former', entityAliases }).request.players[0];
  assert.equal(player.item_key, 'name:endrick|club:chelsea');
  assert.equal(player.current_club_name, null);
  assert.equal(player.former_club_name, 'Palmeiras');
  assert.deepEqual(player.former_club_aliases, []);
  assert.equal(player.destination_club_name, 'Chelsea');
  assert.deepEqual(player.destination_club_aliases, ['Chelsea']);
});

test('generated enrichment request transports former club and curated variants', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const context = {
    transfer_report_id: '25', reported_player_name: 'Endrick', current_club_name: null,
    former_club_name: 'Paris Saint-Germain', destination_club_name: 'Chelsea',
    classification: 'rumor', move_type: 'permanent', provider_player_id: null,
    aliases: [], identity_overrides: [],
  };
  const output = await runRequest({ all: () => [{ json: context }] }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  const player = output[0].json.request.players[0];
  assert.equal(player.former_club_name, 'Paris Saint-Germain');
  assert.ok(player.former_club_aliases.includes('PSG'));
  assert.equal(player.current_club_name, null);
});

test('resolver version mismatch bypasses backoff and ambiguity cooldown', () => {
  const now = Date.parse('2026-07-30T12:00:00Z');
  const context = {
    transfer_report_id: '21',
    reported_player_name: 'Retry Player',
    current_club_name: 'Barcelona',
    destination_club_name: 'Unknown Destination',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: null,
    aliases: [],
    identity_overrides: [],
    latest_attempt_status: 'unresolved',
    latest_attempt_started_at: '2026-07-30T11:00:00Z',
    latest_attempt_next_retry_at: '2026-07-31T11:00:00Z',
  };
  assert.equal(buildEnrichmentRequest([context], { mode: 'active', requestId: 'same-version', now, entityAliases }).request, null);
  const retried = buildEnrichmentRequest([
    context,
    { ...context, transfer_report_id: '22', force_resolver_retry: true },
  ], { mode: 'active', requestId: 'old-version', now, entityAliases });
  assert.deepEqual(retried.request.players[0].report_ids, ['21', '22']);
});

test('generated request bypasses both cooldowns only for a forced resolver retry', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const now = Date.parse('2026-07-30T12:00:00Z');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', `const Date = class extends globalThis.Date { static now() { return ${now}; } };\n${requestNode.parameters.jsCode}`);
  const context = {
    transfer_report_id: '22', reported_player_name: 'Retry Player', current_club_name: 'Barcelona', destination_club_name: 'Other',
    classification: 'rumor', move_type: 'permanent', provider_player_id: null, aliases: [], identity_overrides: [],
    latest_attempt_status: 'unresolved', latest_attempt_started_at: '2026-07-30T11:00:00Z', latest_attempt_next_retry_at: '2026-07-31T11:00:00Z',
  };
  const execute = (value) => runRequest({ all: () => [{ json: value }] }, () => ({ first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }) }));
  assert.equal((await execute(context))[0].json.request, null);
  assert.deepEqual((await execute({ ...context, force_resolver_retry: true }))[0].json.request.players[0].report_ids, ['22']);
});

test('enrichment response normalization converts contract failures into one sanitized result per request item', () => {
  const request = {
    request_id: 'sofascore:1',
    players: [{
      item_key: 'provider:826643',
      reported_name: 'Kylian Mbappé',
      report_ids: ['10'],
      request_context: { reported_name_key: 'kylian mbappé' },
    }],
  };
  const normalized = normalizeEnrichmentResponse(request, {
    statusCode: 200,
    body: {
      request_id: 'sofascore:1',
      items: [{
        item_key: 'provider:826643',
        status: 'fresh',
        resolver_version: 'identity-v7',
        provider_calls: 2,
        identity: {
          provider: 'sofascore',
          provider_player_id: '826643',
          stable_source_identifier: 'sofascore:player:826643',
          score: 80,
          margin: 80,
          resolver_version: 'identity-v7',
        },
        profile: {
          canonical_name: 'Kylian Mbappé',
          current_club: { provider_team_id: '2829', name: 'Real Madrid' },
          retrieved_at: '2026-07-30T00:00:00Z',
        },
        statistics: {
          provider_unique_tournament_id: '8',
          provider_season_id: '77559',
          season_state: 'active',
          scope: 'selected_domestic_league_all_clubs',
          retrieved_at: '2026-07-30T00:00:00Z',
        },
        provenance: { raw_payloads: { profile: {}, statistics: {} } },
      }],
    },
  });
  assert.equal(normalized.items[0].status, 'fresh');
  assert.match(normalized.items[0].profile.content_sha256, /^[a-f0-9]{64}$/);
  const failed = normalizeEnrichmentResponse(request, { statusCode: 200, body: 'not-json' });
  assert.deepEqual(failed.items[0].error, { code: 'enrichment_response_not_json' });
  assert.equal(failed.items[0].identity, null);
});

test('profile-only statistics failures remain renderable partial enrichment', () => {
  const request = {
    request_id: 'sofascore:partial',
    players: [{ item_key: 'provider:826643', reported_name: 'Kylian Mbappé', report_ids: ['10'], request_context: {} }],
  };
  const normalized = normalizeEnrichmentResponse(request, {
    statusCode: 200,
    body: {
      request_id: request.request_id,
      items: [{
        item_key: 'provider:826643',
        status: 'partial',
        resolver_version: 'identity-v9',
        retryable: true,
        identity: {
          provider: 'sofascore',
          provider_player_id: '826643',
          stable_source_identifier: 'sofascore:player:826643',
          score: 80,
          margin: 80,
          resolver_version: 'identity-v9',
        },
        profile: {
          canonical_name: 'Kylian Mbappé',
          current_club: { provider_team_id: '2829', name: 'Real Madrid' },
          retrieved_at: '2026-07-30T00:00:00Z',
        },
        statistics: null,
        warnings: [{ code: 'statistics_unavailable', retryable: true }],
        provenance: { raw_payloads: { profile: {} } },
      }],
    },
  });
  assert.equal(normalized.items[0].status, 'partial');
  assert.equal(normalized.items[0].profile.canonical_name, 'Kylian Mbappé');
  assert.equal(normalized.items[0].statistics, null);
  assert.equal(normalized.items[0].retryable, true);
  assert.deepEqual(normalized.items[0].warning_codes, ['statistics_unavailable']);
});

test('enrichment response normalization preserves valid search candidates with only safe fields', () => {
  const request = {
    request_id: 'sofascore:candidates',
    players: [{ item_key: 'name:john smith|club:current fc', reported_name: 'John Smith', report_ids: ['10'], request_context: {} }],
  };
  const normalized = normalizeEnrichmentResponse(request, {
    statusCode: 200,
    body: {
      request_id: request.request_id,
      items: [{
        item_key: request.players[0].item_key,
        status: 'ambiguous',
        resolver_version: 'identity-v7',
        identity: null,
        profile: null,
        statistics: null,
        candidates: [{
          provider_player_id: '2544168',
          canonical_name: 'John Smith',
          score: 50,
          raw_query_payload: { entity: { id: '2544168' } },
        }],
      }],
    },
  });
  assert.deepEqual(normalized.items[0].candidates, [
    { provider_player_id: '2544168', canonical_name: 'John Smith', score: 50 },
  ]);
});

test('enrichment response rejects identity on unresolved statuses and invalid score margins', () => {
  const player = { item_key: 'provider:9', reported_name: 'Contract Player', report_ids: ['9'], request_context: {} };
  const request = { request_id: 'identity-contract', players: [player] };
  const identity = {
    provider: 'sofascore', provider_player_id: '9', stable_source_identifier: 'sofascore:player:9',
    score: 80, margin: 80, resolver_version: 'identity-v7',
  };
  const response = (status, candidateIdentity) => ({ statusCode: 200, body: {
    request_id: request.request_id,
    items: [{ item_key: player.item_key, status, resolver_version: 'identity-v7', identity: candidateIdentity, profile: null, statistics: null, candidates: [] }],
  } });
  assert.equal(normalizeEnrichmentResponse(request, response('unresolved', identity)).items[0].status, 'schema_failure');
  for (const invalid of [
    { ...identity, score: -1 }, { ...identity, score: 101 },
    { ...identity, margin: -1 }, { ...identity, margin: 101 },
    { ...identity, score: 70, margin: 80 },
  ]) {
    assert.equal(normalizeEnrichmentResponse(request, response('unattached', invalid)).items[0].status, 'schema_failure');
  }
});

test('enrichment response normalization bounds search candidates to five entries', () => {
  const request = {
    request_id: 'sofascore:candidate-limit',
    players: [{ item_key: 'provider:1', reported_name: 'Player', report_ids: ['11'], request_context: {} }],
  };
  const candidates = Array.from({ length: 7 }, (_, index) => ({
    provider_player_id: String(index + 1),
    canonical_name: `Player ${index + 1}`,
    score: 50 - index,
  }));
  const normalized = normalizeEnrichmentResponse(request, {
    statusCode: 200,
    body: { request_id: request.request_id, items: [{ item_key: 'provider:1', status: 'unresolved', resolver_version: 'identity-v7', identity: null, profile: null, statistics: null, candidates }] },
  });
  assert.deepEqual(normalized.items[0].candidates, candidates.slice(0, 5));
});

test('enrichment response normalization omits malformed search candidates', () => {
  const request = {
    request_id: 'sofascore:candidate-safety',
    players: [{ item_key: 'provider:2', reported_name: 'Player', report_ids: ['12'], request_context: {} }],
  };
  const normalized = normalizeEnrichmentResponse(request, {
    statusCode: 200,
    body: {
      request_id: request.request_id,
      items: [{
        item_key: 'provider:2',
        status: 'unresolved',
        resolver_version: 'identity-v7',
        identity: null,
        profile: null,
        statistics: null,
        candidates: [
          { provider_player_id: 'not-a-decimal-id', canonical_name: 'Bad ID', score: 50 },
          { provider_player_id: '2', canonical_name: '', score: 50 },
          { provider_player_id: '3', canonical_name: 'Bad score', score: '50' },
          { provider_player_id: '4', canonical_name: 'Non-finite score', score: Infinity },
          { provider_player_id: 6, canonical_name: 'Numeric ID', score: 50 },
          { provider_player_id: '7', canonical_name: 'Negative score', score: -1 },
          { provider_player_id: '8', canonical_name: 'High score', score: 101 },
          { provider_player_id: '5', canonical_name: ' Valid Name ', score: 0, raw_query_payload: { results: [] } },
        ],
      }],
    },
  });
  assert.deepEqual(normalized.items[0].candidates, [
    { provider_player_id: '5', canonical_name: 'Valid Name', score: 0 },
  ]);
});

test('generated enrichment normalization uses the same bounded candidate contract', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const normalizeNode = workflow.nodes.find((node) => node.name === 'Normalize soccerdata enrichment result');
  const request = {
    request_id: 'sofascore:generated-candidates',
    players: [{ item_key: 'provider:3', reported_name: 'Player', report_ids: ['13'], request_context: {} }],
  };
  const body = {
    request_id: request.request_id,
    items: [{
      item_key: 'provider:3',
      status: 'unresolved',
      resolver_version: 'identity-v7',
      identity: null,
      profile: null,
      statistics: null,
      candidates: [
        { provider_player_id: 'bad', canonical_name: 'Bad ID', score: 50 },
        ...Array.from({ length: 6 }, (_, index) => ({
          provider_player_id: String(index + 10),
          canonical_name: ` Player ${index + 10} `,
          score: 50 - index,
          raw_query_payload: { results: [] },
        })),
      ],
    }],
  };
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runNormalize = new AsyncFunction('$json', '$', normalizeNode.parameters.jsCode);
  const output = await runNormalize({ statusCode: 200, body }, (name) => {
    assert.equal(name, 'Build soccerdata enrichment request');
    return { first: () => ({ json: { request, workflow_run_id: '1' } }) };
  });
  assert.deepEqual(output[0].json.normalized.items[0].candidates, [
    { provider_player_id: '10', canonical_name: 'Player 10', score: 50 },
    { provider_player_id: '11', canonical_name: 'Player 11', score: 49 },
    { provider_player_id: '12', canonical_name: 'Player 12', score: 48 },
    { provider_player_id: '13', canonical_name: 'Player 13', score: 47 },
    { provider_player_id: '14', canonical_name: 'Player 14', score: 46 },
  ]);
  const invalidIdentity = {
    provider: 'sofascore', provider_player_id: '3', stable_source_identifier: 'sofascore:player:3',
    score: 70, margin: 80, resolver_version: 'identity-v7',
  };
  const invalidOutput = await runNormalize({ statusCode: 200, body: {
    ...body, items: [{ ...body.items[0], identity: invalidIdentity }],
  } }, () => ({ first: () => ({ json: { request, workflow_run_id: '1' } }) }));
  assert.equal(invalidOutput[0].json.normalized.items[0].status, 'schema_failure');
});

test('retry timing honors server headers within a bounded exponential backoff policy', () => {
  assert.equal(retryDelayMs({ attempt: 1, retryAfter: '3', now: 0 }), 3000);
  assert.equal(retryDelayMs({ attempt: 3, retryAfter: null, now: 0 }), 4000);
  assert.equal(retryDelayMs({ attempt: 1, rateResetEpochSeconds: 10, now: 0 }), 10000);
  assert.equal(retryDelayMs({ attempt: 1, retryAfter: '99999', maximumMs: 300000, now: 0 }), 300000);
  assert.equal(shouldRetry('twscrape', 503), true);
  assert.equal(shouldRetry('qwen', 0), true);
  assert.equal(shouldRetry('discord', 400), false);
  assert.equal(shouldRetry('discord', 429), true);
});

test('digest selection allows only important positions 16 through 18 and respects Discord limits', () => {
  const reports = Array.from({ length: 22 }, (_, index) => ({
    ...validReport({ player_name: `Player ${index}`, classification: 'official_confirmed', confidence: 0.9 }),
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

test('digest prioritizes confirmed reports, Romano or Ornstein, huge rumors, then €70m or £70m rumors', () => {
  const ordinary = { ...validReport({ player_name: 'Ordinary', classification: 'advanced_negotiations' }), preferred_source: source('someone') };
  const bigMoney = { ...validReport({ player_name: 'Big Money', fee_amount: 70000000, fee_currency: 'EUR' }), preferred_source: source('someone') };
  const huge = { ...validReport({ player_name: 'Huge', is_huge_rumor: true }), preferred_source: source('someone') };
  const ornstein = { ...validReport({ player_name: 'Ornstein', classification: 'rumor' }), preferred_source: source('David_Ornstein') };
  const confirmed = { ...validReport({ player_name: 'Confirmed', classification: 'official_confirmed' }), preferred_source: source('someone') };
  assert.deepEqual(selectDigestReports([ordinary, bigMoney, huge, ornstein, confirmed]).map((report) => report.player_name), ['Confirmed', 'Ornstein', 'Huge', 'Big Money', 'Ordinary']);
  assert.equal(selectDigestReports([{ ...bigMoney, fee_currency: 'USD' }, ordinary])[0].player_name, 'Ordinary');
});

test('digest positions 16 through 18 exclude huge and big-money rumors', () => {
  const reports = [
    ...Array.from({ length: 16 }, (_, index) => ({ ...validReport({ player_name: `Confirmed ${index}`, classification: 'official_confirmed' }), preferred_source: source('someone') })),
    { ...validReport({ player_name: 'Huge extra', is_huge_rumor: true }), preferred_source: source('someone') },
    { ...validReport({ player_name: 'Big money extra', fee_amount: 70000000, fee_currency: 'GBP' }), preferred_source: source('someone') },
    { ...validReport({ player_name: 'Romano extra' }), preferred_source: source('FabrizioRomano') },
  ];
  const selected = selectDigestReports(reports);
  assert.equal(selected.length, 17);
  assert.deepEqual(selected.slice(15).map((report) => report.player_name), ['Confirmed 15', 'Romano extra']);
  assert.ok(!selected.some((report) => ['Huge extra', 'Big money extra'].includes(report.player_name)));
});

test('digest requires relevance and complete clubs, then keeps the highest-ranked story per player surname', () => {
  const samePlayerLowerPriority = { ...validReport({ player_name: 'Same Player', destination_club_name: 'Club A' }), preferred_source: source('someone'), revision_id: '1' };
  const samePlayerPreferred = { ...validReport({ player_name: 'Same Player', destination_club_name: 'Club B', classification: 'official_confirmed' }), preferred_source: source('David_Ornstein'), revision_id: '2' };
  const lowProfile = { ...validReport({ player_name: 'Low Profile', is_digest_worthy: false }), preferred_source: source('David_Ornstein'), revision_id: '3' };
  const incomplete = { ...validReport({ player_name: 'Incomplete', current_club_name: 'not_reported' }), preferred_source: source('David_Ornstein'), revision_id: '4' };
  assert.deepEqual(selectDigestReports([samePlayerLowerPriority, samePlayerPreferred, lowProfile, incomplete]).map((report) => report.destination_club_name), ['Club B']);
});

test('digest uses fresh active profile club only as a bounded presentation fallback', () => {
  const fallback = {
    ...validReport({ current_club_name: null, destination_club_name: 'Chelsea', classification: 'rumor' }),
    preferred_source: source('someone'),
    enrichment: { profile: { current_club_name: 'Real Madrid', stale: false } },
  };
  const digest = buildDiscordDigest([fallback], { entityAliases });
  assert.match(digest.embeds[0].fields[0].value, /^Real Madrid → Chelsea/m);
  assert.equal(fallback.current_club_name, null);
  for (const overrides of [
    { classification: 'official_confirmed' },
    { move_type: 'loan' },
    { enrichment: { profile: { current_club_name: 'Real Madrid', stale: true } } },
    { enrichment: { profile: { current_club_name: 'Chelsea FC', stale: false } } },
    { pending_idempotency_key: 'pending' },
  ]) {
    assert.equal(selectDigestReports([{ ...fallback, ...overrides }], { entityAliases }).length, 0);
  }
  const sourceWins = { ...fallback, current_club_name: 'Palmeiras' };
  assert.match(buildDiscordDigest([sourceWins], { entityAliases }).embeds[0].fields[0].value, /^Real Madrid → Chelsea/m);
});

test('digest keeps distinct destinations from one post and uses the fresh profile club', () => {
  const enrichment = { profile: { current_club_name: 'Chelsea', stale: false } };
  const reports = [
    {
      ...validReport({ player_name: 'Nicolas Jackson', current_club_name: 'Atlético Madrid', destination_club_name: 'Aston Villa', confidence: 0.9 }),
      preferred_source: { ...source('FabrizioRomano'), display_name: 'Fabrizio Romano' },
      sources: [{ post_url: 'https://x.com/FabrizioRomano/status/1' }],
      revision_id: 'jackson-villa',
      enrichment,
    },
    {
      ...validReport({ player_name: 'Nicolas Jackson', current_club_name: 'Atlético Madrid', destination_club_name: 'Atlético Madrid', confidence: 0.95 }),
      preferred_source: { ...source('FabrizioRomano'), display_name: 'Fabrizio Romano' },
      sources: [{ post_url: 'https://x.com/FabrizioRomano/status/1' }],
      revision_id: 'jackson-atleti',
      enrichment,
    },
  ];
  const selected = selectDigestReports(reports, { entityAliases });
  assert.deepEqual(selected.map((report) => report.destination_club_name), ['Atlético Madrid', 'Aston Villa']);
  const value = buildDiscordDigest(reports, { entityAliases }).embeds[0].fields.map((field) => field.value).join('\n');
  assert.match(value, /Chelsea → Atlético Madrid/);
  assert.match(value, /Chelsea → Aston Villa/);
  assert.match(value, /Confidence of Model Understanding \(CoMU\): 95%/);
  assert.match(value, /Confidence of Model Understanding \(CoMU\): 90%/);
});

test('digest renders active probability details and labels legacy confidence honestly', () => {
  const active = {
    ...validReport({ player_name: 'Active Player' }),
    preferred_source: source('David_Ornstein'),
    revision_id: 'active-probability',
    probability_status: 'active_scored',
    probability: {
      engine_version: 'probability-v1',
      normalized_probability: 0.62,
      previous_probability: 0.51,
      probability_delta: 0.11,
      current_stage: 'advanced',
      terminal_state: 'open',
      explanation: {
        primary: { reliability: 0.87 },
        corroboration: [{ independence_key: 'reporter:second' }],
        contradictions: [],
        story_staleness_adjustment: 0,
        competition_adjustment: -0.06,
        change_classification: 'raw_score_change',
      },
    },
  };
  const legacy = {
    ...validReport({ player_name: 'Legacy Example', confidence: 0.73 }),
    preferred_source: source('someone'),
    revision_id: 'legacy-confidence',
    probability_status: 'legacy_unscored',
  };
  const values = buildDiscordDigest([active, legacy]).embeds[0].fields.map((field) => field.value);
  assert.match(values[0], /Probability: 62% \(▲ \+11\)/);
  assert.match(values[0], /Stage: Advanced talks/);
  assert.match(values[0], /Why: strong primary report \(87% reliability\); \+1 independent source/);
  assert.doesNotMatch(values[0], /competition/);
  assert.doesNotMatch(values[0], /Confidence:/);
  assert.match(values[1], /Confidence of Model Understanding \(CoMU\): 73%/);
  assert.doesNotMatch(values[1], /Probability:/);
  const prior = {
    ...active,
    probability: { ...active.probability, normalized_probability: 0.51, previous_probability: null, probability_delta: null },
  };
  assert.equal(buildDiscordDigest([{
    ...active,
    sent_history: [{ snapshot: prior, sent_at: '2026-08-27T00:00:00.000Z' }],
  }]).embeds[0].fields.length, 1);
});

test('digest preserves exact legacy confidence and rejects malformed active probability', () => {
  for (const probability_status of ['legacy_unscored', 'shadow_scored']) {
    const report = {
      ...validReport({ player_name: `Legacy ${probability_status}`, confidence: 0.73 }),
      preferred_source: source('someone'),
      revision_id: `legacy-${probability_status}`,
      probability_status,
      probability: { normalized_probability: 0.91 },
    };
    const value = buildDiscordDigest([report]).embeds[0].fields[0].value;
    assert.match(value, /Confidence of Model Understanding \(CoMU\): 73%/);
    assert.doesNotMatch(value, /Legacy extraction confidence/);
    assert.doesNotMatch(value, /Probability:/);
  }

  const malformed = {
    ...validReport({ player_name: 'Malformed active' }),
    preferred_source: source('someone'),
    revision_id: 'malformed-active',
    probability_status: 'active_scored',
    probability: { explanation: {} },
  };
  assert.throws(
    () => buildDiscordDigest([malformed]),
    /active_scored.*deterministic probability/i,
  );
});

test('generated digest preserves legacy confidence and rejects malformed active probability', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const candidate = (status, probability) => ({ json: { row_type: 'candidate', payload: {
    revision_id: `generated-${status}`,
    snapshot: { ...validReport({ player_name: `Generated ${status}`, confidence: 0.73 }), probability_status: status, probability },
    post_url: 'https://example.test/generated', priority_rank: '2', reliability_score: '0.95',
    source_username: 'someone', source_name: 'Someone',
  } } });
  for (const status of ['legacy_unscored', 'shadow_scored']) {
    const output = await runDigest({ all: () => [candidate(status, { normalized_probability: 0.91 })] });
    const payload = JSON.parse(output[0].json.params[0]);
    assert.match(payload.discord_payload.embeds[0].fields[0].value, /Confidence of Model Understanding \(CoMU\): 73%/);
  }
  await assert.rejects(
    runDigest({ all: () => [candidate('active_scored', { explanation: {} })] }),
    /active_scored.*deterministic probability/i,
  );
});

test('competition reason is causal, negative-only, and wins the single negative slot', () => {
  const render = (probability_delta, explanation) => buildDiscordDigest([{
    ...validReport({ player_name: `Competition ${probability_delta}` }),
    preferred_source: source('David_Ornstein'), revision_id: String(probability_delta),
    probability_status: 'active_scored',
    probability: {
      engine_version: 'probability-v1', normalized_probability: 0.40,
      previous_probability: 0.46, probability_delta, current_stage: 'talks', terminal_state: 'open',
      explanation: {
        primary: { reliability: 0.87 },
        corroboration: [{ independence_key: 'reporter:second' }, { independence_key: 'reporter:third' }],
        ...explanation,
      },
    },
  }]).embeds[0].fields[0].value;
  const competitionOnly = render(-0.06, {
    change_classification: 'competition_only', competition_adjustment: -0.06,
    contradictions: [{}], story_staleness_adjustment: -0.35,
  });
  assert.match(competitionOnly, /Why: strong primary report \(87% reliability\); \+2 independent sources; -6 pts from competition/);
  assert.doesNotMatch(competitionOnly, /contradictory|stale/);
  const positive = render(0.06, {
    change_classification: 'competition_only', competition_adjustment: -0.06,
    contradictions: [], story_staleness_adjustment: 0,
  });
  assert.doesNotMatch(positive, /competition/);
});

test('active probability rendering covers initial, down, zero, done, official, and collapsed states', () => {
  const render = (probability) => buildDiscordDigest([{
    ...validReport({ player_name: `State ${probability.terminal_state ?? probability.current_stage}` }),
    preferred_source: source('David_Ornstein'), revision_id: JSON.stringify(probability),
    probability_status: 'active_scored', probability: { engine_version: 'probability-v1', explanation: {}, ...probability },
  }]).embeds[0].fields[0].value;
  assert.match(render({ normalized_probability: 0.18, previous_probability: null, probability_delta: null, current_stage: 'interest', terminal_state: 'open' }), /Probability: 18%\nStage: Interest/);
  assert.match(render({ normalized_probability: 0.44, previous_probability: 0.55, probability_delta: -0.11, current_stage: 'talks', terminal_state: 'open' }), /Probability: 44% \(▼ -11\)/);
  assert.match(render({ normalized_probability: 0.55, previous_probability: 0.55, probability_delta: 0, current_stage: 'advanced', terminal_state: 'open' }), /Probability: 55% \(— 0\)/);
  assert.match(render({ normalized_probability: 0.98, previous_probability: 0.96, probability_delta: 0.02, current_stage: 'done', terminal_state: 'open' }), /Stage: Done · awaiting official announcement/);
  assert.match(render({ normalized_probability: 0.99, previous_probability: 0.98, probability_delta: 0.01, current_stage: 'done', terminal_state: 'official' }), /Probability: 100%.*\nStage: Official confirmation/);
  assert.match(render({ normalized_probability: 0.02, previous_probability: 0.30, probability_delta: -0.28, current_stage: 'collapsed', terminal_state: 'collapsed' }), /Stage: Collapsed/);
});

test('generated digest applies presentation fallback without changing the frozen snapshot', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const snapshot = validReport({ player_name: 'Endrick', current_club_name: null, destination_club_name: 'Chelsea' });
  const output = await runDigest({ all: () => [{ json: { row_type: 'candidate', payload: {
    revision_id: 'fallback', snapshot,
    enrichment: { profile: { current_club_name: 'Real Madrid', stale: false } },
    post_url: 'https://example.test/endrick', priority_rank: '2', reliability_score: '0.95',
    source_username: 'David_Ornstein', source_name: 'David Ornstein',
  } } }] });
  const payload = JSON.parse(output[0].json.params[0]);
  assert.match(payload.discord_payload.embeds[0].fields[0].value, /^Real Madrid → Chelsea/m);
  assert.equal(snapshot.current_club_name, null);
});

test('digest sends material updates, suppresses confirmed moves for seven days, and allows a deal-off', () => {
  const now = Date.parse('2026-07-30T12:00:00.000Z');
  const sentRumor = validReport({ player_name: 'Kerim Alajbegovic', current_club_name: 'Bayer 04 Leverkusen', destination_club_name: 'Juventus', fee_amount: 33000000, fee_currency: 'EUR' });
  const confirmation = validReport({ player_name: 'Kerim Alajbegović', current_club_name: 'Bayer Leverkusen', destination_club_name: 'Juventus', classification: 'official_confirmed', fee_amount: 35000000, fee_currency: 'EUR', revision_id: 'confirmed', sent_history: [{ snapshot: sentRumor, sent_at: '2026-07-30T06:00:00.000Z' }] });
  assert.equal(selectDigestReports([confirmation], { entityAliases, now }).length, 1);
  const confirmedUpdate = { ...confirmation, fee_amount: 36000000, revision_id: 'confirmed-update', sent_history: [{ snapshot: confirmation, sent_at: '2026-07-30T11:00:00.000Z' }] };
  assert.equal(selectDigestReports([confirmedUpdate], { entityAliases, now }).length, 0);
  const dealOff = { ...confirmedUpdate, classification: 'rejected_failed', revision_id: 'deal-off' };
  assert.equal(selectDigestReports([dealOff], { entityAliases, now }).length, 1);
});

test('sent history matches canonical player and destination instead of surname batch identity', () => {
  const sentAt = '2026-07-30T06:00:00.000Z';
  const history = (snapshot) => [{ snapshot, sent_at: sentAt }];
  const alex = validReport({ player_name: 'Alex Smith', destination_club_name: 'Arsenal' });
  const jamie = { ...validReport({ player_name: 'Jamie Smith', destination_club_name: 'Arsenal' }), revision_id: 'jamie', sent_history: history(alex) };
  const oldDestination = validReport({ player_name: 'Same Player', destination_club_name: 'Arsenal' });
  const newDestination = { ...validReport({ player_name: 'Same Player', destination_club_name: 'Liverpool' }), revision_id: 'new-destination', sent_history: history(oldDestination) };
  assert.deepEqual(selectDigestReports([jamie, newDestination]).map(({ revision_id }) => revision_id), ['jamie', 'new-destination']);
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
  assert.doesNotMatch(value, /Identity:/);
});

test('digest renders fresh same-currency fee context compactly and fails open otherwise', () => {
  const base = validReport({
    fee_amount: 25000000,
    fee_currency: 'EUR',
    add_ons_amount: 5000000,
    add_ons_currency: 'EUR',
  });
  const fresh = buildDiscordDigest([{
    ...base,
    fee_context: {
      profile_snapshot_id: '42',
      market_value: 20000000,
      market_value_currency: 'EUR',
      market_value_as_of: '2026-08-27T00:00:00Z',
      stale: false,
      guaranteed_fee_ratio: 1.25,
      fee_plus_add_ons_ratio: 1.5,
    },
  }]).embeds[0].fields[0].value;
  assert.match(fresh, /Fee: €25m \+ €5m add-ons · Sofascore value €20m \(1\.25x guaranteed, 1\.5x incl\. add-ons, fresh\)/);
  assert.doesNotMatch(fresh, /^Add-ons:/m);

  for (const fee_context of [
    { profile_snapshot_id: '43', market_value: 20000000, market_value_currency: 'EUR', stale: true, guaranteed_fee_ratio: 1.25, fee_plus_add_ons_ratio: 1.5 },
    { profile_snapshot_id: '44', market_value: 20000000, market_value_currency: 'GBP', stale: false },
  ]) {
    const value = buildDiscordDigest([{ ...base, fee_context }]).embeds[0].fields[0].value;
    assert.match(value, /^Fee: 25,000,000 EUR$/m);
    assert.match(value, /^Add-ons: 5,000,000 EUR$/m);
    assert.doesNotMatch(value, /Sofascore value/);
  }

  const partial = buildDiscordDigest([{
    ...base,
    add_ons_currency: 'GBP',
    fee_context: {
      profile_snapshot_id: '45', market_value: 20000000,
      market_value_currency: 'EUR', stale: false, guaranteed_fee_ratio: 1.25,
    },
  }]).embeds[0].fields[0].value;
  assert.match(partial, /^Fee: €25m · Sofascore value €20m \(1\.25x guaranteed, fresh\)$/m);
  assert.match(partial, /^Add-ons: 5,000,000 GBP$/m);
  assert.doesNotMatch(partial, /incl\. add-ons/);
});

test('fee context alone does not make a delivered report material', () => {
  const delivered = validReport({ fee_amount: 25000000, fee_currency: 'EUR' });
  const enriched = {
    ...delivered,
    revision_id: 'fee-context-only',
    fee_context: {
      profile_snapshot_id: '42', market_value: 20000000,
      market_value_currency: 'EUR', stale: false, guaranteed_fee_ratio: 1.25,
    },
    sent_history: [{ snapshot: delivered, sent_at: '2026-08-27T00:00:00Z' }],
  };
  assert.equal(selectDigestReports([enriched], { now: Date.parse('2026-08-27T01:00:00Z') }).length, 0);
});

test('digest appends rich enrichment in whole groups and keeps the journalist link last', () => {
  const postUrl = 'https://x.com/David_Ornstein/status/999000000000000002';
  const report = {
    ...validReport({ player_name: 'Kylian Mbappé' }),
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    sources: [{ post_url: postUrl }],
    enrichment: richEnrichment({
      statistics: {
        ...richEnrichment().statistics,
        retrieved_at: '2026-07-29T12:00:00Z',
        stale: true,
      },
    }),
  };
  const embed = buildDiscordDigest([report], { now: Date.parse('2026-07-30T06:00:00Z') }).embeds[0];
  const value = embed.fields[0].value;
  assert.match(value, /Confidence of Model Understanding \(CoMU\): 70%\n\*\*Player profile & statistics\*\*\nProfile:/);
  assert.match(value, /Profile: Real Madrid · France · 27 · Forward · Sofascore value €191m/);
  assert.match(value, /LaLiga 2025\/26 - all clubs: 31 app · 2,604 min · 25 G · 5 A · 29 starts · 84 min\/app · 23\.95 xG · 6\.20 xA · 7\.56 rating · stale 18h/);
  assert.doesNotMatch(value, /Advanced:/);
  assert.match(value, /Details: Born 1998-12-20 · 180 cm · Right foot/);
  assert.match(value, /Other: 3 yellow · 0 red/);
  assert.ok(value.endsWith(`[David Ornstein](${postUrl})`));
  assert.ok(value.length <= 1024);
  assert.ok(discordCharacterCount(embed) <= 6000);
});

test('goalkeeper statistics render only for goalkeeper profiles in library and generated digests', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const cases = [
    { primaryPosition: 'Forward', showsGoalkeeperStatistics: false },
    { primaryPosition: undefined, showsGoalkeeperStatistics: false },
    { primaryPosition: 'Goalkeeper', showsGoalkeeperStatistics: true },
  ];

  for (const [index, { primaryPosition, showsGoalkeeperStatistics }] of cases.entries()) {
    const profile = { ...richEnrichment().profile, primary_position: primaryPosition };
    if (primaryPosition === undefined) delete profile.primary_position;
    const enrichment = richEnrichment({
      profile,
      statistics: {
        ...richEnrichment().statistics,
        goalkeeper_clean_sheets: 11,
        goalkeeper_saves: 87,
      },
    });
    if (primaryPosition === 'Goalkeeper') {
      enrichment.statistics = {
        ...enrichment.statistics,
        competition: enrichment.statistics.competition_name,
        season: enrichment.statistics.season_label,
        minutes_per_game: enrichment.statistics.minutes_per_appearance,
        clean_sheets: enrichment.statistics.goalkeeper_clean_sheets,
        saves: enrichment.statistics.goalkeeper_saves,
      };
      delete enrichment.statistics.competition_name;
      delete enrichment.statistics.season_label;
      delete enrichment.statistics.minutes_per_appearance;
      delete enrichment.statistics.goalkeeper_clean_sheets;
      delete enrichment.statistics.goalkeeper_saves;
    }
    const postUrl = `https://x.com/David_Ornstein/status/${999000000000000500n + BigInt(index)}`;
    const report = {
      ...validReport({ player_name: `Position ${index}` }),
      revision_id: `position-${index}`,
      dedupe_key: `position-${index}|test-fc|destination-fc`,
      preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
      sources: [{ post_url: postUrl }],
      enrichment,
      ...(index === 0 ? {
        probability_status: 'active_scored',
        probability: {
          engine_version: 'probability-v1', normalized_probability: 0.62,
          previous_probability: 0.51, probability_delta: 0.11,
          current_stage: 'advanced', terminal_state: 'open',
          explanation: { primary: { reliability: 0.87 }, corroboration: [], contradictions: [] },
        },
      } : {}),
    };
    const libraryPayload = buildDiscordDigest([report]);
    const output = await runDigest({ all: () => [{ json: {
      row_type: 'candidate',
      payload: {
        revision_id: report.revision_id,
        snapshot: report,
        enrichment,
        post_url: postUrl,
        priority_rank: '2',
        reliability_score: '0.95',
        source_username: 'David_Ornstein',
        source_name: 'David Ornstein',
      },
    } }] });
    const generatedPayload = JSON.parse(output[0].json.params[0]).discord_payload;
    const value = libraryPayload.embeds[0].fields[0].value;

    if (showsGoalkeeperStatistics) {
      assert.match(value, /11 clean sheets · 87 saves/);
    } else {
      assert.doesNotMatch(value, /clean sheets|saves/);
    }
    assert.deepEqual(generatedPayload, libraryPayload);
  }
});

test('digest canonicalizes first and applies configured common-surname conflicts', () => {
  const report = (playerName, destinationClubName, confidence = 0.7) => ({
    ...validReport({ player_name: playerName, destination_club_name: destinationClubName, confidence }),
    revision_id: `${playerName}-${destinationClubName}`,
  });
  assert.deepEqual(
    selectDigestReports([report('Rodri', 'Real Madrid'), report('Rodri Hernandez', 'Barcelona', 0.9)], { entityAliases }).map(({ player_name }) => player_name),
    ['Rodri Hernández'],
  );
  assert.deepEqual(
    selectDigestReports([report('Akilouche', 'Arsenal'), report('Maghnes Akliouche', 'Liverpool', 0.9)], { entityAliases }).map(({ player_name }) => player_name),
    ['Maghnes Akliouche'],
  );
  assert.equal(selectDigestReports([report('Alex Smith', 'Arsenal'), report('Jamie Smith', 'Liverpool', 0.9)], { entityAliases }).length, 2);
  assert.equal(selectDigestReports([report('Cristian Romero', 'Arsenal'), report('Luka Romero', 'Liverpool')], { entityAliases }).length, 2);
  assert.equal(selectDigestReports([report('Romero', 'Arsenal'), report('Cristian Romero', 'Liverpool')], { entityAliases }).length, 1);
  assert.equal(selectDigestReports([report('J. Martinez', 'Arsenal'), report('Juan Martinez', 'Liverpool')], { entityAliases }).length, 1);
  assert.equal(selectDigestReports([report('José Luis Rodriguez', 'Arsenal'), report('Luis Rodriguez', 'Liverpool')], { entityAliases }).length, 1);
  assert.equal(selectDigestReports([report('Bruno Fernandes', 'Arsenal'), report('Enzo Fernandes', 'Liverpool')], { entityAliases }).length, 2);
  assert.equal(selectDigestReports([report('Cristian Romero', 'Arsenal'), report('Cuti Romero', 'Liverpool')], { entityAliases }).length, 1);
  assert.equal(selectDigestReports([report('Alex Unlisted', 'Arsenal'), report('Jamie Unlisted', 'Liverpool')], { entityAliases }).length, 1);
  assert.equal(selectDigestReports([report('Kylian Mbappé', 'Arsenal'), report('Ethan Mbappé', 'Liverpool')], { entityAliases }).length, 2);
  assert.equal(selectDigestReports([report('Jurriën Timber', 'Arsenal'), report('Quinten Timber', 'Liverpool')], { entityAliases }).length, 2);
  assert.equal(selectDigestReports([
    report('Kylian Mbappé', 'Arsenal'),
    report('Ethan Mbappé', 'Liverpool'),
    report('Jordan Mbappé', 'Chelsea', 0.9),
  ], { entityAliases }).length, 1);
  const aliasesWithSiblingVariant = {
    ...entityAliases,
    players: { ...entityAliases.players, 'kylian mbappe': 'Kylian Mbappé' },
  };
  assert.equal(selectDigestReports([
    report('Kylian Mbappe', 'Arsenal'),
    report('Kylian Mbappé', 'Barcelona'),
    report('Ethan Mbappé', 'Liverpool'),
  ], { entityAliases: aliasesWithSiblingVariant }).length, 2);
});

test('digest renders null or failed enrichment as the unchanged transfer-only story', () => {
  const report = {
    ...validReport(),
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    sources: [{ post_url: 'https://x.com/David_Ornstein/status/999000000000000003' }],
  };
  const transferOnly = buildDiscordDigest([report]).embeds[0].fields[0].value;
  for (const enrichment of [
    null,
    { profile: null, statistics: null },
    { profile: null, statistics: null, error: { code: 'provider_failure' } },
    {
      profile: { current_club_name: 'unknown', market_value: 100, market_value_currency: null },
      statistics: { competition_name: 'N/A', season_label: null, scope: null },
    },
  ]) {
    const value = buildDiscordDigest([{ ...report, enrichment }]).embeds[0].fields[0].value;
    assert.equal(value, transferOnly);
    assert.doesNotMatch(value, /Player profile|Profile|Advanced|Sofascore|provider|unknown|N\/A/);
  }
});

test('digest enrichment budget tries the compact profile when the statistics group does not fit', () => {
  const base = {
    ...validReport({ player_name: 'Budget Test' }),
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    enrichment: richEnrichment(),
  };
  let accepted;
  for (let length = 400; length < 900; length += 1) {
    const postUrl = `https://x.com/source/status/999000000000000004?context=${'a'.repeat(length)}`;
    const payload = buildDiscordDigest([{ ...base, sources: [{ post_url: postUrl }] }]);
    const field = payload.embeds[0].fields[0];
    if (field?.value.includes('Profile:') && !field.value.includes('LaLiga')) {
      accepted = { payload, field, postUrl };
      break;
    }
  }
  assert.ok(accepted);
  assert.match(accepted.field.value, /Profile: Real Madrid/);
  assert.match(accepted.field.value, /\*\*Player profile & statistics\*\*/);
  assert.doesNotMatch(accepted.field.value, /LaLiga|Advanced:/);
  assert.ok(accepted.field.value.endsWith(`[David Ornstein](${accepted.postUrl})`));
  assert.ok(accepted.field.value.length <= 1024);
  assert.ok(discordCharacterCount(accepted.payload.embeds[0]) <= 6000);
});

test('digest admits only fully budgeted enriched stories under the 6,000-character limit', () => {
  const reports = Array.from({ length: 18 }, (_, index) => ({
    ...validReport({
      player_name: `Enriched Budget ${index}`,
      classification: 'official_confirmed',
      fee_amount: 123456789,
      fee_currency: 'EUR',
    }),
    revision_id: String(index + 1),
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    sources: [{ post_url: `https://x.com/source/status/${999000000000000300n + BigInt(index)}` }],
    enrichment: richEnrichment(),
  }));
  const embed = buildDiscordDigest(reports).embeds[0];
  assert.ok(embed.fields.length > 1);
  assert.ok(embed.fields.every((field) => field.value.includes('**Player profile & statistics**')));
  assert.ok(embed.fields.every((field) => field.value.endsWith(')')));
  assert.ok(embed.fields.every((field) => field.value.length <= 1024));
  assert.ok(discordCharacterCount(embed) <= 6000);
});

test('generated digest renders the same rich enrichment labels within Discord limits', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const snapshot = { ...validReport({ player_name: 'Kylian Mbappé' }), dedupe_key: 'kylian-mbappe|real-madrid|liverpool' };
  const input = [{ json: {
    row_type: 'candidate',
    payload: {
      revision_id: 'revision-rich',
      snapshot,
      enrichment: richEnrichment(),
      post_url: 'https://x.com/David_Ornstein/status/999000000000000005',
      priority_rank: '2',
      reliability_score: '0.95',
      source_username: 'David_Ornstein',
      source_name: 'David Ornstein',
    },
  } }];
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const output = await runDigest({ all: () => input });
  const payload = JSON.parse(output[0].json.params[0]).discord_payload;
  const embed = payload.embeds[0];
  const value = embed.fields[0].value;
  assert.match(value, /Sofascore value €191m/);
  assert.match(value, /LaLiga 2025\/26 - all clubs:/);
  assert.ok(value.endsWith('[David Ornstein](https://x.com/David_Ornstein/status/999000000000000005)'));
  assert.ok(embed.fields.every((field) => field.value.length <= 1024));
  assert.ok(discordCharacterCount(embed) <= 6000);
});

test('digest omits active-season statistics', () => {
  const report = {
    ...validReport({ player_name: 'Active Season' }),
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    sources: [{ post_url: 'https://x.com/source/status/999000000000000008' }],
    enrichment: richEnrichment({ statistics: { ...richEnrichment().statistics, season_state: 'active' } }),
  };
  const value = buildDiscordDigest([report]).embeds[0].fields[0].value;
  assert.doesNotMatch(value, /LaLiga 2025\/26/);
  assert.match(value, /Profile: Real Madrid/);
});

test('fresh lower-only statistics keep competition context in library and generated digests', async () => {
  const enrichment = richEnrichment({
    profile: null,
    statistics: {
      ...richEnrichment().statistics,
      appearances: null,
      starts: null,
      minutes_played: null,
      minutes_per_appearance: null,
      goals: null,
      expected_goals: null,
      assists: null,
      expected_assists: null,
      average_rating: null,
      yellow_cards: 2,
      red_cards: 0,
    },
  });
  const postUrl = 'https://x.com/David_Ornstein/status/999000000000000007';
  const report = {
    ...validReport({ player_name: 'Lower Only' }),
    revision_id: 'lower-only',
    dedupe_key: 'lower-only|test-fc|destination-fc',
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    sources: [{ post_url: postUrl }],
    enrichment,
  };
  const libraryPayload = buildDiscordDigest([report]);

  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const output = await runDigest({ all: () => [{ json: {
    row_type: 'candidate',
    payload: {
      revision_id: report.revision_id,
      snapshot: report,
      enrichment,
      post_url: postUrl,
      priority_rank: '2',
      reliability_score: '0.95',
      source_username: 'David_Ornstein',
      source_name: 'David Ornstein',
    },
  } }] });
  const generatedPayload = JSON.parse(output[0].json.params[0]).discord_payload;
  const value = libraryPayload.embeds[0].fields[0].value;
  assert.match(value, /LaLiga 2025\/26 - all clubs\nOther: 2 yellow · 0 red/);
  assert.doesNotMatch(value, /Advanced:/);
  assert.deepEqual(generatedPayload, libraryPayload);
});

test('generated digest applies surname deduplication and exact sibling exceptions', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const candidate = (revisionId, playerName, destinationClubName, confidence = 0.7) => ({ json: {
    row_type: 'candidate',
    payload: {
      revision_id: revisionId,
      snapshot: validReport({ player_name: playerName, destination_club_name: destinationClubName, confidence }),
      post_url: `https://x.com/source/status/${revisionId}`,
      priority_rank: '2',
      reliability_score: '0.95',
      source_name: 'Source',
    },
  } });
  const output = await runDigest({ all: () => [
    { json: { row_type: 'sent_history', payload: [] } },
    candidate('1', 'Rodri', 'Arsenal'),
    candidate('2', 'Rodri Hernandez', 'Liverpool', 0.9),
    candidate('3', 'Alex Smith', 'Arsenal'),
    candidate('4', 'Jamie Smith', 'Liverpool', 0.9),
    candidate('5', 'Kylian Mbappé', 'Arsenal'),
    candidate('6', 'Ethan Mbappé', 'Liverpool'),
  ] });
  const payload = JSON.parse(output[0].json.params[0]);
  assert.deepEqual(payload.discord_payload.embeds[0].fields.map(({ name }) => name), [
    '1. Rodri Hernández',
    '2. Jamie Smith',
    '3. Alex Smith',
    '4. Kylian Mbappé',
    '5. Ethan Mbappé',
  ]);
  const selectedCount = async (names) => {
    const result = await runDigest({ all: () => [
      { json: { row_type: 'sent_history', payload: [] } },
      ...names.map((name, index) => candidate(String(100 + index), name, `Club ${index}`)),
    ] });
    return JSON.parse(result[0].json.params[0]).revision_ids.length;
  };
  assert.equal(await selectedCount(['Cristian Romero', 'Luka Romero']), 2);
  assert.equal(await selectedCount(['Romero', 'Cristian Romero']), 1);
  assert.equal(await selectedCount(['J. Martinez', 'Juan Martinez']), 1);
  assert.equal(await selectedCount(['José Luis Rodriguez', 'Luis Rodriguez']), 1);
  assert.equal(await selectedCount(['Bruno Fernandes', 'Enzo Fernandes']), 2);
  assert.equal(await selectedCount(['Cristian Romero', 'Cuti Romero']), 1);
  assert.equal(await selectedCount(['Alex Unlisted', 'Jamie Unlisted']), 1);
  const mixedFamily = await runDigest({ all: () => [
    { json: { row_type: 'sent_history', payload: [] } },
    candidate('5', 'Kylian Mbappé', 'Arsenal'),
    candidate('6', 'Ethan Mbappé', 'Liverpool'),
    candidate('7', 'Jordan Mbappé', 'Chelsea', 0.9),
  ] });
  assert.deepEqual(JSON.parse(mixedFamily[0].json.params[0]).revision_ids, ['7']);
});

test('generated digest keeps history identity separate from surname batch identity', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const candidate = (revisionId, snapshot) => ({ json: { row_type: 'candidate', payload: {
    revision_id: revisionId,
    snapshot,
    post_url: `https://x.com/source/status/${revisionId}`,
    priority_rank: '2',
    reliability_score: '0.95',
    source_name: 'Source',
  } } });
  const sentHistory = [
    { snapshot: validReport({ player_name: 'Alex Smith', destination_club_name: 'Arsenal' }), sent_at: '2026-07-30T06:00:00.000Z' },
    { snapshot: validReport({ player_name: 'Same Player', destination_club_name: 'Arsenal' }), sent_at: '2026-07-30T06:00:00.000Z' },
  ];
  const output = await runDigest({ all: () => [
    { json: { row_type: 'sent_history', payload: sentHistory } },
    candidate('jamie', validReport({ player_name: 'Jamie Smith', destination_club_name: 'Arsenal' })),
    candidate('new-destination', validReport({ player_name: 'Same Player', destination_club_name: 'Liverpool' })),
  ] });
  assert.deepEqual(JSON.parse(output[0].json.params[0]).revision_ids, ['jamie', 'new-destination']);
});

test('enrichment request modes, freshness, cooldown, dedupe, and maximum batch are fail-closed', () => {
  const base = {
    transfer_report_id: '1',
    reported_player_name: 'Nguyễn Quang Hải',
    current_club_name: 'Công An Hà Nội',
    destination_club_name: 'Destination FC',
    classification: 'rumor',
    move_type: 'permanent',
    provider_player_id: '845067',
    aliases: [],
    identity_overrides: [],
    profile_fresh_until: null,
    statistics_fresh_until: null,
    profile_current_provider_team_id: '193616',
    team_mapping_fresh: false,
    season_mapping_fresh: false,
  };
  assert.deepEqual(buildEnrichmentRequest([base], { mode: 'off', requestId: 'off' }), {
    mode: 'off',
    refreshRequired: false,
    request: null,
  });
  assert.equal(buildEnrichmentRequest([base], { mode: 'shadow', requestId: 'shadow' }).mode, 'shadow');
  assert.equal(buildEnrichmentRequest([base], { mode: 'active', requestId: 'active' }).mode, 'active');

  const future = new Date(Date.now() + 60_000).toISOString();
  const fresh = buildEnrichmentRequest([{
    ...base,
    profile_fresh_until: future,
    statistics_fresh_until: future,
  }], { mode: 'active', requestId: 'fresh' });
  assert.equal(fresh.refreshRequired, false);
  assert.equal(fresh.request, null);

  const cooldown = buildEnrichmentRequest([{
    ...base,
    provider_player_id: null,
    latest_attempt_status: 'ambiguous',
    latest_attempt_started_at: new Date().toISOString(),
  }], { mode: 'active', requestId: 'cooldown' });
  assert.equal(cooldown.refreshRequired, false);

  const contexts = Array.from({ length: 30 }, (_, index) => ({
    ...base,
    transfer_report_id: String(index + 1),
    provider_player_id: String(900000 + index),
    is_digest_worthy: true,
    source_username: 'someone',
    source_priority_rank: 4,
    source_reliability_score: 0.7,
  }));
  contexts[25] = {
    ...contexts[25],
    classification: 'official_confirmed',
    source_username: 'realmadrid',
    source_priority_rank: 1,
    source_reliability_score: 1,
  };
  const bounded = buildEnrichmentRequest(contexts, { mode: 'active', requestId: 'bounded' });
  assert.equal(bounded.request.players.length, 25);
  assert.equal(new Set(bounded.request.players.map((player) => player.item_key)).size, 25);
  assert.ok(bounded.request.players.some((player) => player.report_ids.includes('26')));
  assert.ok(!bounded.request.players.some((player) => player.report_ids.includes('25')));
  assert.equal(bounded.request.players[0].destination_club_name, 'Destination FC');
});

test('generated enrichment request gives digest-priority players the bounded batch slots', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const contexts = Array.from({ length: 30 }, (_, index) => ({
    transfer_report_id: String(index + 1),
    reported_player_name: `Player ${index + 1}`,
    current_club_name: 'Current FC',
    destination_club_name: 'Destination FC',
    classification: index === 25 ? 'official_confirmed' : 'rumor',
    move_type: 'permanent',
    is_digest_worthy: true,
    provider_player_id: String(900000 + index),
    aliases: [],
    identity_overrides: [],
    source_username: index === 25 ? 'realmadrid' : 'someone',
    source_priority_rank: index === 25 ? 1 : 4,
    source_reliability_score: index === 25 ? 1 : 0.7,
  }));
  const output = await runRequest({ all: () => contexts.map((json) => ({ json })) }, () => ({
    first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }),
  }));
  const players = output[0].json.request.players;
  assert.equal(players.length, 25);
  assert.ok(players.some((player) => player.report_ids.includes('26')));
  assert.ok(!players.some((player) => player.report_ids.includes('25')));
  assert.equal(players[0].destination_club_name, 'Destination FC');
});

test('current enrichment contexts precede higher-priority historical retries in library and generated requests', async () => {
  const historical = Array.from({ length: 33 }, (_, index) => ({
    transfer_report_id: String(index + 1), reported_player_name: `History ${index + 1}`,
    current_club_name: 'Current FC', destination_club_name: 'Destination FC',
    classification: 'official_confirmed', move_type: 'permanent', is_digest_worthy: true,
    provider_player_id: String(910000 + index), aliases: [], identity_overrides: [],
    source_username: 'realmadrid', source_priority_rank: 1, source_reliability_score: 1,
    is_current_request: false,
  }));
  const current = [
    { ...historical[0], transfer_report_id: '101', reported_player_name: 'Cuti Romero', current_club_name: 'Tottenham', provider_player_id: null, classification: 'rumor', source_username: 'someone', is_current_request: true },
    { ...historical[0], transfer_report_id: '102', reported_player_name: 'Lukaku', current_club_name: 'Napoli', provider_player_id: null, classification: 'rumor', source_username: 'someone', is_current_request: true },
  ];
  const contexts = [...historical, ...current];
  const libraryPlayers = buildEnrichmentRequest(contexts, { mode: 'active', requestId: 'current-first', entityAliases }).request.players;
  assert.deepEqual(libraryPlayers.slice(0, 2).map(({ reported_name }) => reported_name), ['Cristian Romero', 'Romelu Lukaku']);

  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$', requestNode.parameters.jsCode);
  const generated = await runRequest({ all: () => contexts.map((json) => ({ json })) }, () => ({ first: () => ({ json: { mode: 'active', workflow_run_id: '1' } }) }));
  assert.deepEqual(generated[0].json.request.players.slice(0, 2).map(({ reported_name }) => reported_name), ['Cristian Romero', 'Romelu Lukaku']);
});

test('enrichment response rejects JSON null, duplicate keys, wrong request IDs, and malformed typed fields', () => {
  const request = {
    request_id: 'contract:1',
    players: [{
      item_key: 'provider:826643',
      reported_name: 'Kylian Mbappé',
      report_ids: ['10'],
      request_context: {},
    }],
  };
  const identity = {
    provider: 'sofascore',
    provider_player_id: '826643',
    stable_source_identifier: 'sofascore:player:826643',
    score: 80,
    margin: 80,
  };
  const profile = {
    canonical_name: 'Kylian Mbappé',
    current_club: { provider_team_id: '2829', name: 'Real Madrid' },
    market_value_currency: 'EUR',
    retrieved_at: '2026-07-30T00:00:00Z',
  };
  const statistics = {
    provider_unique_tournament_id: '8',
    provider_season_id: '77559',
    season_state: 'latest_completed',
    scope: 'selected_domestic_league_all_clubs',
    retrieved_at: '2026-07-30T00:00:00Z',
  };
  const body = (overrides = {}) => ({
    request_id: request.request_id,
    items: [{ item_key: 'provider:826643', status: 'fresh', identity, profile, statistics, ...overrides }],
  });
  for (const response of [
    { body: { request_id: 'wrong', items: [] } },
    { body: { ...body(), items: [...body().items, ...body().items] } },
    { body: body({ profile: null }) },
    { body: body({ statistics: null }) },
    { body: body({ profile: { ...profile, market_value_currency: 'eur' } }) },
    { body: body({ statistics: { ...statistics, scope: 'guessed' } }) },
  ]) {
    const normalized = normalizeEnrichmentResponse(request, { statusCode: 200, ...response });
    assert.equal(normalized.items[0].status, 'schema_failure');
    assert.equal(normalized.items[0].identity, null);
  }
});

test('Discord stale windows, unknown currency, sparse stats context, and zero values are exact', () => {
  const now = Date.parse('2026-07-30T12:00:00Z');
  const base = {
    ...validReport({ player_name: 'Boundary Player' }),
    preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
    sources: [{ post_url: 'https://x.com/source/status/999000000000000006' }],
  };
  const render = (enrichment) => buildDiscordDigest(
    [{ ...base, enrichment }],
    { now },
  ).embeds[0].fields[0].value;

  const statsOnly = richEnrichment({
    profile: null,
    statistics: {
      ...richEnrichment().statistics,
      appearances: null,
      minutes_played: null,
      goals: null,
      assists: null,
      expected_goals: 1.25,
      yellow_cards: 0,
    },
  });
  const sparse = render(statsOnly);
  assert.match(sparse, /LaLiga 2025\/26 - all clubs: 29 starts · 84 min\/app · 1\.25 xG/);
  assert.doesNotMatch(sparse, /Advanced:/);
  assert.match(sparse, /Other: 0 yellow · 0 red/);

  const justInside = render(richEnrichment({
    statistics: {
      ...richEnrichment().statistics,
      stale: true,
      retrieved_at: new Date(now - 72 * 60 * 60 * 1000).toISOString(),
    },
  }));
  assert.match(justInside, /stale 3d/);
  const outside = render(richEnrichment({
    profile: null,
    statistics: {
      ...richEnrichment().statistics,
      stale: true,
      retrieved_at: new Date(now - 72 * 60 * 60 * 1000 - 1).toISOString(),
    },
  }));
  assert.doesNotMatch(outside, /LaLiga|Advanced|Other/);

  const unattachedInside = render({
    profile: {
      ...richEnrichment().profile,
      current_club_name: null,
      stale: true,
      retrieved_at: new Date(now - 7 * 24 * 60 * 60 * 1000).toISOString(),
    },
    statistics: null,
  });
  assert.match(unattachedInside, /Profile · stale 7d/);
  const unattachedOutside = render({
    profile: {
      ...richEnrichment().profile,
      current_club_name: null,
      stale: true,
      retrieved_at: new Date(now - 7 * 24 * 60 * 60 * 1000 - 1).toISOString(),
    },
    statistics: null,
  });
  assert.doesNotMatch(unattachedOutside, /Profile/);

  const currency = render(richEnrichment({
    profile: { ...richEnrichment().profile, market_value_currency: 'VND' },
  }));
  assert.match(currency, /191m VND/);
  assert.doesNotMatch(render(richEnrichment({
    profile: { ...richEnrichment().profile, market_value_currency: null },
  })), /Sofascore value/);
});

test('Discord exact field-name, value, aggregate, embed, and field-count boundaries are preserved', () => {
  const reports = Array.from({ length: 25 }, (_, index) => ({
    ...validReport({
      player_name: `Boundary Player ${index}`,
      classification: 'official_confirmed',
      confidence: 0.9,
    }),
    revision_id: String(index + 1),
    preferred_source: { ...source('David_Ornstein'), display_name: 'Source' },
    sources: [{ post_url: `https://x.com/source/status/${999000000000000100n + BigInt(index)}` }],
  }));
  const payload = buildDiscordDigest(reports);
  assert.equal(payload.embeds.length, 1);
  assert.ok(payload.embeds.length <= 10);
  assert.equal(payload.embeds[0].fields.length, 18);
  assert.ok(payload.embeds[0].fields.length <= 25);
  assert.ok(payload.embeds[0].fields.every((field) => field.name.length <= 256));
  assert.ok(payload.embeds[0].fields.every((field) => field.value.length <= 1024));
  assert.ok(discordCharacterCount(payload.embeds[0]) <= 6000);

  const longName = buildDiscordDigest([{
    ...reports[0],
    player_name: `${'👨‍👩‍👧‍👦'.repeat(40)} boundary`,
    revision_id: 'long-name',
  }]).embeds[0].fields[0].name;
  assert.ok(longName.length <= 256);
  assert.ok(longName.endsWith('…'));
  assert.doesNotMatch(longName, /\u200d…$/u);
});

test('library and generated Discord formatters match across rich, sparse, null, and failure cases', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const cases = [
    richEnrichment(),
    {
      profile: { current_club_name: 'Công An Hà Nội', nationality: 'Vietnam', retrieved_at: '2026-07-30T00:00:00Z' },
      statistics: {
        competition_name: 'V-League 1',
        season_label: '2025/26',
        scope: 'selected_domestic_league_all_clubs',
        appearances: 24,
        retrieved_at: '2026-07-30T00:00:00Z',
      },
    },
    null,
    { profile: null, statistics: null, error: { code: 'provider_failure' } },
  ];
  for (const [index, enrichment] of cases.entries()) {
    const postUrl = `https://x.com/David_Ornstein/status/${999000000000000200n + BigInt(index)}`;
    const report = {
      ...validReport({
        player_name: `Parity ${index}`,
        ...(index === 0 ? {
          fee_amount: 25000000, fee_currency: 'EUR',
          add_ons_amount: 5000000, add_ons_currency: 'EUR',
        } : {}),
      }),
      revision_id: `parity-${index}`,
      dedupe_key: `parity-${index}|test-fc|destination-fc`,
      preferred_source: { ...source('David_Ornstein'), display_name: 'David Ornstein' },
      sources: [{ post_url: postUrl }],
      enrichment,
      ...(index === 0 ? { fee_context: {
        profile_snapshot_id: '42', market_value: 20000000,
        market_value_currency: 'EUR', market_value_as_of: '2026-08-27T00:00:00Z',
        stale: false, guaranteed_fee_ratio: 1.25, fee_plus_add_ons_ratio: 1.5,
      } } : {}),
    };
    const generatedInput = [{ json: {
      row_type: 'candidate',
      payload: {
        revision_id: report.revision_id,
        snapshot: report,
        enrichment,
        post_url: postUrl,
        priority_rank: '2',
        reliability_score: '0.95',
        source_username: 'David_Ornstein',
        source_name: 'David Ornstein',
      },
    } }];
    const generated = await runDigest({ all: () => generatedInput });
    const generatedPayload = JSON.parse(generated[0].json.params[0]).discord_payload;
    const libraryPayload = buildDiscordDigest([report]);
    assert.deepEqual(generatedPayload, libraryPayload);
    if (index === 0) assert.match(generatedPayload.embeds[0].fields[0].value, /1\.5x incl\. add-ons/);
  }
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
  const hashInput = { ...payload.snapshot };
  delete hashInput.is_digest_worthy;
  const expected = createHash('sha256').update(JSON.stringify(hashInput)).digest('hex');
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

test('generated twscrape adapter preserves string IDs, keeps quoted posts, filters retweets, and tolerates partial failures', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const adapter = workflow.nodes.find((node) => node.name === 'Normalize twscrape posts');
  const request = {
    sources: [
      { source_id: 'source-1', external_account_id: '922928582866980864', username: 'charlotteharpur', display_name: 'Charlotte Harpur', priority_rank: 4, reliability_score: 0.7, is_official: false },
      { source_id: 'source-2', external_account_id: '330262748', username: 'unavailable', display_name: 'Unavailable', priority_rank: 5, reliability_score: 0.5, is_official: false },
    ],
  };
  const response = {
    posts: [
      { source_id: 'source-1', username: 'charlotteharpur', x_user_id: '922928582866980864', external_post_id: '900000000000000101', post_url: 'https://x.com/charlotteharpur/status/900000000000000101', content: 'Direct transfer report', posted_at: '2026-07-26T00:00:00.000Z', raw_payload: { id: '900000000000000101' } },
      { source_id: 'source-1', username: 'charlotteharpur', x_user_id: '922928582866980864', external_post_id: '900000000000000102', post_url: 'https://x.com/charlotteharpur/status/900000000000000102', content: 'Quote comment\n\nQuoted post:\nQuoted transfer report', posted_at: '2026-07-26T00:01:00.000Z', raw_payload: { id: '900000000000000102' } },
      { source_id: 'source-1', username: 'charlotteharpur', x_user_id: '922928582866980864', external_post_id: '900000000000000103', post_url: 'https://x.com/charlotteharpur/status/900000000000000103', content: 'RT @source: pure retweet', posted_at: '2026-07-26T00:02:00.000Z', raw_payload: { id: '900000000000000103' } },
      { source_id: 'source-1', username: 'charlotteharpur', x_user_id: '922928582866980864', external_post_id: '900000000000000104', post_url: 'https://x.com/charlotteharpur/status/900000000000000104', content: 'Stale transfer report', posted_at: '2026-07-25T23:59:59.999Z', raw_payload: { id: '900000000000000104' } },
      { source_id: 'source-1', username: 'charlotteharpur', x_user_id: '922928582866980864', external_post_id: '900000000000000105', post_url: 'https://x.com/charlotteharpur/status/900000000000000105', content: 'Future transfer report', posted_at: '2026-07-26T06:00:00.001Z', raw_payload: { id: '900000000000000105' } },
    ],
    errors: [{ source_id: 'source-2', username: 'unavailable', x_user_id: '330262748', code: 'account_unavailable', message: 'X account unavailable', retryable: true }],
  };
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runAdapter = new AsyncFunction('$input', '$', adapter.parameters.jsCode);
  const output = await runAdapter({ first: () => ({ json: { body: response } }) }, (name) => {
    if (name === 'Create run context') return { isExecuted: true, first: () => ({ json: { collection_cutoff_at: '2026-07-26T00:00:00.000Z', collection_started_at: '2026-07-26T06:00:00.000Z' } }) };
    if (name === 'Create sample run context') return { isExecuted: false };
    assert.equal(name, 'Build twscrape collect request');
    return { first: () => ({ json: request }) };
  });
  assert.equal(output.length, 2);
  assert.equal(output[0].json.params[0], '922928582866980864');
  assert.equal(typeof output[0].json.params[0], 'string');
  assert.equal(output[0].json.params[1], '900000000000000101');
  assert.match(output[1].json.params[3], /Quoted post:\nQuoted transfer report/);
});

test('generated twscrape adapter fails when every requested source errors', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const adapter = workflow.nodes.find((node) => node.name === 'Normalize twscrape posts');
  const request = {
    sources: [
      { source_id: 'source-1', external_account_id: '922928582866980864', username: 'charlotteharpur' },
      { source_id: 'source-2', external_account_id: '330262748', username: 'unavailable' },
    ],
  };
  const response = {
    posts: [],
    errors: [
      { source_id: 'source-1', code: 'account_unavailable' },
      { source_id: 'source-2', code: 'timeout' },
    ],
  };
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runAdapter = new AsyncFunction('$input', '$', adapter.parameters.jsCode);
  await assert.rejects(
    () => runAdapter({ first: () => ({ json: { body: response } }) }, (name) => {
      assert.equal(name, 'Build twscrape collect request');
      return { first: () => ({ json: request }) };
    }),
    /twscrape collection failed for 2 source\(s\): account_unavailable, timeout/,
  );
});

test('generated twscrape adapter keeps a legitimate empty collection as a no-op', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const adapter = workflow.nodes.find((node) => node.name === 'Normalize twscrape posts');
  const request = { sources: [{ source_id: 'source-1', external_account_id: '922928582866980864', username: 'charlotteharpur' }] };
  const response = { posts: [], errors: [] };
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runAdapter = new AsyncFunction('$input', '$', adapter.parameters.jsCode);
  const output = await runAdapter({ first: () => ({ json: { body: response } }) }, (name) => {
    if (name === 'Create run context') return { isExecuted: true, first: () => ({ json: { collection_cutoff_at: '2026-07-26T00:00:00.000Z', collection_started_at: '2026-07-26T06:00:00.000Z' } }) };
    if (name === 'Create sample run context') return { isExecuted: false };
    assert.equal(name, 'Build twscrape collect request');
    return { first: () => ({ json: request }) };
  });
  assert.deepEqual(output, []);
});

test('generated error workflow preserves the n8n execution ID for failure linkage', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor-errors.json', import.meta.url), 'utf8'));
  const prepareNode = workflow.nodes.find((node) => node.name === 'Prepare failure record');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runPrepare = new AsyncFunction('$json', prepareNode.parameters.jsCode);
  const output = await runPrepare({ execution: { id: 'execution-42', error: { name: 'Error', message: 'collector unavailable' } } });
  assert.deepEqual(output[0].json.params.slice(0, 5), [
    'execution-42', 'workflow_error', 'execution-42|collector unavailable', 'Error', 'collector unavailable',
  ]);
  assert.equal(typeof output[0].json.params[5], 'string');
});

test('generated collector selector permits only twscrape', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const selector = workflow.nodes.find((node) => node.name === 'Select X collector');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runSelector = new AsyncFunction('$input', '$env', selector.parameters.jsCode);
  const output = await runSelector({ all: () => [{ json: { source_account_id: '1' } }] }, { X_COLLECTOR: 'twscrape' });
  assert.equal(output[0].json.collector, 'twscrape');
  await assert.rejects(() => runSelector({ all: () => [{ json: {} }] }, { X_COLLECTOR: 'unsupported' }), /X_COLLECTOR/);
});

test('generated digest deduplicates repeated candidate rows before applying its 15/18 limit', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const snapshot = { ...validReport(), dedupe_key: 'alvaro-test|test-fc|destination-fc' };
  const repeated = [
    { json: { row_type: 'sent_history', payload: [] } },
    ...Array.from({ length: 20 }, () => ({ json: { row_type: 'candidate', payload: {
      revision_id: 'revision-1', snapshot, post_url: 'https://x.com/source/status/1', priority_rank: '2', reliability_score: '0.95', source_name: 'Source',
    } } })),
  ];
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const output = await runDigest({ all: () => repeated });
  assert.equal(output.length, 1);
  const payload = JSON.parse(output[0].json.params[0]);
  assert.deepEqual(payload.revision_ids, ['revision-1']);
  assert.equal(payload.discord_payload.embeds[0].fields.length, 1);
});

test('generated pending delivery preserves the stored JSONB payload structurally through Discord delivery', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const deliveryNode = workflow.nodes.find((node) => node.name === 'Build Discord delivery request');
  const storedPayload = JSON.parse(JSON.stringify({
    allowed_mentions: { parse: [] },
    embeds: [{ title: 'Frozen payload', fields: [{ name: 'Original', value: 'Stored', inline: false }] }],
  }));
  const candidate = { json: { row_type: 'candidate', payload: {
    revision_id: 'pending-revision', snapshot: validReport(), post_url: 'https://example.test/pending',
    priority_rank: '2', reliability_score: '0.95', source_name: 'Source',
    pending_idempotency_key: 'pending-key', pending_window_started_at: '2026-08-09T00:00:00Z',
    pending_window_ended_at: '2026-08-09T06:00:00Z', pending_request_payload: storedPayload,
  } } };
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runDigest = new AsyncFunction('$input', digestNode.parameters.jsCode);
  const digestOutput = await runDigest({ all: () => [{ json: { row_type: 'sent_history', payload: [] } }, candidate] });
  const reserved = JSON.parse(digestOutput[0].json.params[0]);
  assert.deepEqual(reserved.discord_payload, storedPayload);

  const runDelivery = new AsyncFunction('$json', deliveryNode.parameters.jsCode);
  const deliveryOutput = await runDelivery({ digest_delivery_id: '1', request_payload: JSON.stringify(storedPayload) });
  assert.deepEqual(deliveryOutput[0].json.body, storedPayload);
});

test('generated workflow carries fail-closed shadow and active probability evidence', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const requestNode = workflow.nodes.find((node) => node.name === 'Build Qwen request');
  const parserNode = workflow.nodes.find((node) => node.name === 'Validate Qwen response');
  const mergeNode = workflow.nodes.find((node) => node.name === 'Merge extracted reports');
  const persistNode = workflow.nodes.find((node) => node.name === 'Persist merged reports and revisions');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runRequest = new AsyncFunction('$input', '$env', '$', requestNode.parameters.jsCode);
  const input = { all: () => [{ json: {
    raw_post_id: '41', external_post_id: '42', post_url: 'https://x.com/test/status/42',
    posted_at: '2026-08-27T01:02:03.000Z', content: 'fixture', ...source('test'),
  } }] };
  const lookup = () => ({ first: () => ({ json: { collection_started_at: '2026-08-27T01:05:00.000Z' } }) });

  for (const [configured, expected] of [[undefined, 'off'], ['', 'off'], ['active', 'active'], ['invalid', 'off'], [' SHADOW ', 'shadow']]) {
    const [request] = await runRequest(input, { PROBABILITY_MODE: configured }, lookup);
    assert.equal(request.json.probability_mode, expected, String(configured));
    assert.equal(request.json.evaluated_at, '2026-08-27T01:05:00.000Z');
  }

  const [request] = await runRequest(input, { PROBABILITY_MODE: 'shadow' }, lookup);
  const response = { json: { choices: [{ message: { content: JSON.stringify({
    transfer_related: true,
    reports: [evidenceReport({ destination_club_name: 'Club A' }), evidenceReport({ destination_club_name: 'Club B', stage_signal: 'advanced' })],
  }) } }] }, pairedItem: { item: 0 } };
  const runParser = new AsyncFunction('$input', '$', parserNode.parameters.jsCode);
  const parsed = await runParser({ all: () => [response] }, () => ({ all: () => [request] }));
  assert.deepEqual(parsed.map((item) => item.json.report.report_ordinal), [1, 2]);
  for (const item of parsed) {
    const report = item.json.report;
    assert.equal(report.extraction_schema_version, 'qwen-evidence-v1');
    assert.equal(report.probability_mode, 'shadow');
    assert.equal(report.evaluated_at, '2026-08-27T01:05:00.000Z');
    assert.deepEqual(Object.keys(report.normalized_evidence).sort(), [
      'attribution_kind', 'claim_stance', 'club_agreement_state', 'completion_claim',
      'extraction_confidence', 'named_originator', 'personal_terms_state', 'stage_signal', 'wording_strength',
    ]);
  }

  const runMerge = new AsyncFunction('$input', mergeNode.parameters.jsCode);
  const shadowPayloads = await runMerge({ all: () => parsed });
  assert.equal(shadowPayloads.length, 2);
  for (const item of shadowPayloads) {
    const payload = JSON.parse(item.json.params[0]);
    assert.equal(payload.probability_mode, 'shadow');
    assert.equal(payload.evaluated_at, '2026-08-27T01:05:00.000Z');
    assert.equal(payload.sources[0].report_ordinal, 1 + (payload.destination_club_name === 'Club B'));
    assert.equal(payload.sources[0].extraction_schema_version, 'qwen-evidence-v1');
    assert.equal(payload.sources[0].normalized_evidence.destination_club_name, undefined);
    for (const [field, value] of Object.entries(payload.sources[0].normalized_evidence)) {
      assert.deepEqual(payload.sources[0][field], value, field);
    }
  }

  const [activeRequest] = await runRequest(input, { PROBABILITY_MODE: 'active' }, lookup);
  const activeParsed = await runParser({ all: () => [response] }, () => ({ all: () => [activeRequest] }));
  const [activeMerged] = await runMerge({ all: () => activeParsed });
  const activePayload = JSON.parse(activeMerged.json.params[0]);
  assert.equal(activePayload.probability_mode, 'active');
  assert.deepEqual(activePayload.processed_post_external_ids, ['42']);
  assert.equal(workflow.connections['Persist merged reports and revisions'].main[0][0].node, 'Prepare merged processed-post Redis write');
  assert.equal(workflow.connections['Resume merged processing after Redis'].main[0][0].node, 'Prepare preferred source reset');
  assert.equal(persistNode.typeVersion, 2.6);
  assert.match(persistNode.parameters.query, /probability_mode.*shadow/is);
  assert.match(persistNode.parameters.query, /apply_probability_v1_shadow/);
  assert.match(persistNode.parameters.query, /apply_probability_v1_active/);
  assert.equal(workflow.connections['Daily probability decay'].main[0][0].node, 'Recover interrupted stale deliveries');
  assert.equal(workflow.connections['Recompute stale probability cases'].main[0][0].node, 'Prepare digest candidates query');
  assert.match(workflow.nodes.find((node) => node.name === 'Recompute stale probability cases').parameters.query, /recompute_stale_probability_v1_cases/);
  assert.match(workflow.nodes.find((node) => node.name === 'Recompute stale probability cases').parameters.query, /settle_expired_probability_v1_cases/);
  const staleContextNode = workflow.nodes.find((node) => node.name === 'Create stale recompute context');
  const runStaleContext = new AsyncFunction('$env', '$execution', staleContextNode.parameters.jsCode);
  for (const configured of [undefined, '', 'off', 'invalid']) {
    assert.deepEqual(await runStaleContext({ PROBABILITY_MODE: configured }, { id: 'stale-off' }), []);
  }
  const activeStale = await runStaleContext({ PROBABILITY_MODE: ' ACTIVE ' }, { id: 'stale-active' });
  assert.equal(activeStale.length, 1);
  assert.equal(activeStale[0].json.probability_mode, 'active');
  assert.equal(workflow.connections['Create stale recompute context'].main[0][0].node, 'Register stale workflow run');
});

test('generated extraction preserves future effective dates and connected loan siblings', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const parserNode = workflow.nodes.find((node) => node.name === 'Validate Qwen response');
  const mergeNode = workflow.nodes.find((node) => node.name === 'Merge extracted reports');
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const request = { json: {
    raw_post_id: '99', external_post_id: '100', post_url: 'https://x.com/fabrizio/status/100',
    posted_at: '2026-09-01T00:00:00.000Z', source: source('fabrizioromano'),
  } };
  const response = { json: { choices: [{ message: { content: JSON.stringify({
    transfer_related: true,
    reports: [
      evidenceReport({ player_name: 'Honest Ahanor', current_club_name: 'Atalanta', destination_club_name: 'Chelsea', classification: 'official_confirmed', move_type: 'permanent', move_effective_on: '2027-06', is_digest_worthy: true }),
      evidenceReport({ player_name: 'Honest Ahanor', current_club_name: 'Atalanta', destination_club_name: 'Crystal Palace', classification: 'loan', move_type: 'loan', is_digest_worthy: false }),
    ],
  }) } }] }, pairedItem: { item: 0 } };
  const runParser = new AsyncFunction('$input', '$', parserNode.parameters.jsCode);
  const parsed = await runParser({ all: () => [response] }, () => ({ all: () => [request] }));
  assert.equal(parsed.length, 2);
  assert.equal(parsed[0].json.report.move_effective_on, '2027-06');
  assert.equal((await runParser({ all: () => [{ json: { choices: [{ message: { content: JSON.stringify({ transfer_related: true, reports: [evidenceReport({ move_effective_on: '2027-6' })] }) } }] }, pairedItem: { item: 0 } }] }, () => ({ all: () => [request] })))[0].json.valid, false);
  const runMerge = new AsyncFunction('$input', mergeNode.parameters.jsCode);
  const payloads = await runMerge({ all: () => parsed });
  assert.equal(payloads.length, 2);
  const snapshots = payloads.map((item) => JSON.parse(item.json.params[0]).snapshot);
  assert.ok(snapshots.every((snapshot) => snapshot.is_digest_worthy === true));
  assert.ok(snapshots.some((snapshot) => snapshot.move_effective_on === '2027-06'));
  assert.ok(snapshots.some((snapshot) => snapshot.destination_club_name === 'Crystal Palace'));
});

test('standard n8n deployment exposes probability mode to main and runner services', async () => {
  const compose = await readFile(new URL('../../deploy/n8n/compose.yaml', import.meta.url), 'utf8');
  const serviceBlock = (name, nextName) => compose.slice(
    compose.indexOf(`  ${name}:`),
    nextName ? compose.indexOf(`  ${nextName}:`) : compose.length,
  );
  const expected = '- PROBABILITY_MODE=${PROBABILITY_MODE:-off}';
  assert.match(serviceBlock('n8n', 'n8n-runner'), new RegExp(expected.replace(/[${}]/g, '\\$&')));
  assert.match(serviceBlock('n8n-runner', 'twscrape'), new RegExp(expected.replace(/[${}]/g, '\\$&')));
});

test('generated workflow stays in sync with the registry and extraction contract', async () => {
  const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
  const errorWorkflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor-errors.json', import.meta.url), 'utf8'));
  const sourceNode = workflow.nodes.find((node) => node.name === 'Load generated sources');
  const qwenNode = workflow.nodes.find((node) => node.name === 'Build Qwen request');
  const collectorNode = workflow.nodes.find((node) => node.name === 'Select X collector');
  const twscrapeBuilderNode = workflow.nodes.find((node) => node.name === 'Build twscrape collect request');
  const twscrapeNode = workflow.nodes.find((node) => node.name === 'Collect 20 X posts via twscrape');
  const twscrapeParserNode = workflow.nodes.find((node) => node.name === 'Normalize twscrape posts');
  const qwenParserNode = workflow.nodes.find((node) => node.name === 'Validate Qwen response');
  const mergeExtractedNode = workflow.nodes.find((node) => node.name === 'Merge extracted reports');
  const sampleNode = workflow.nodes.find((node) => node.name === 'Load sample collected X posts');
  const reserveNode = workflow.nodes.find((node) => node.name === 'Reserve digest before delivery');
  const candidatesNode = workflow.nodes.find((node) => node.name === 'Find undelivered revisions');
  const digestNode = workflow.nodes.find((node) => node.name === 'Build bounded Discord digest');
  const contextNode = workflow.nodes.find((node) => node.name === 'Load player enrichment contexts');
  const requestNode = workflow.nodes.find((node) => node.name === 'Build soccerdata enrichment request');
  const enrichNode = workflow.nodes.find((node) => node.name === 'Enrich players via soccerdata');
  const persistEnrichmentNode = workflow.nodes.find((node) => node.name === 'Persist soccerdata enrichment result');
  const deliveryRequestNode = workflow.nodes.find((node) => node.name === 'Build Discord delivery request');
  const mergeReportsNode = workflow.nodes.find((node) => node.name === 'Persist merged reports and revisions');
  const runNode = workflow.nodes.find((node) => node.name === 'Register workflow run');
  const recoveryNode = workflow.nodes.find((node) => node.name === 'Recover interrupted deliveries');
  const failureNode = errorWorkflow.nodes.find((node) => node.name === 'Upsert workflow failure');
  assert.match(sourceNode.parameters.jsCode, /922928582866980864/);
  assert.match(qwenNode.parameters.jsCode, /football_transfer_extraction/);
  assert.match(qwenNode.parameters.jsCode, /explicitly stated current employer or registration holder/);
  assert.match(qwenNode.parameters.jsCode, /women's, girls', and youth football/);
  assert.match(qwenNode.parameters.jsCode, /Women's-football blacklist/);
  assert.match(qwenNode.parameters.jsCode, /Misa Rodríguez/);
  assert.match(qwenNode.parameters.jsCode, /Misa Rodriguez/);
  assert.match(qwenNode.parameters.jsCode, /Known football siblings/);
  assert.match(qwenNode.parameters.jsCode, /Normalized common football surnames/);
  assert.match(qwenNode.parameters.jsCode, /preserve any first or given name stated/);
  assert.match(qwenNode.parameters.jsCode, /never reorder a surname-first name/);
  assert.match(qwenNode.parameters.jsCode, /A rejected bid is `stage_signal=setback` plus `club_agreement_state=rejected`/);
  assert.match(qwenNode.parameters.jsCode, /official_announcement` describes wording only/);
  assert.match(qwenNode.parameters.jsCode, /not the likelihood that the move completes/);
  assert.match(qwenNode.parameters.jsCode, /Never output any percentage, transfer probability/);
  assert.match(qwenNode.parameters.jsCode, /"extraction_confidence"/);
  assert.doesNotMatch(qwenNode.parameters.jsCode, /"confidence":\s*\{\s*"type"/);
  assert.match(qwenParserNode.parameters.jsCode, /Randal Kolo Muani/);
  assert.match(qwenParserNode.parameters.jsCode, /report\.extraction_confidence/);
  assert.doesNotMatch(qwenParserNode.parameters.jsCode, /report\.confidence/);
  assert.match(collectorNode.parameters.jsCode, /X_COLLECTOR/);
  assert.match(twscrapeBuilderNode.parameters.jsCode, /limit: 20/);
  assert.match(twscrapeNode.parameters.url, /TWSCRAPE_BASE_URL/);
  assert.equal(twscrapeNode.parameters.options.timeout, 310000);
  assert.match(twscrapeParserNode.parameters.jsCode, /Build twscrape collect request/);
  assert.match(twscrapeParserNode.parameters.jsCode, /twscrape collection failed/);
  assert.match(collectorNode.parameters.jsCode, /twscrape/);
  assert.doesNotMatch(collectorNode.parameters.jsCode, /rapidapi/i);
  assert.equal(workflow.nodes.some((node) => /rapidapi/i.test(node.name)), false);
  assert.match(failureNode.parameters.query, /UPDATE workflow_runs/);
  assert.match(failureNode.parameters.query, /external_execution_id = \$1/);
  assert.match(failureNode.parameters.query, /status = 'failed'/);
  assert.match(failureNode.parameters.query, /finished_at = COALESCE/);
  assert.match(failureNode.parameters.query, /INSERT INTO failures \(workflow_run_id,/);
  assert.doesNotMatch(qwenParserNode.parameters.jsCode, /itemMatching/);
  assert.match(qwenNode.parameters.jsCode, /delete llamaSchema\.properties\.reports\.items\.properties\.player_name\.minLength/);
  assert.match(qwenParserNode.parameters.jsCode, /report\.player_name\.trim\(\)\.length > 0/);
  assert.match(qwenParserNode.parameters.jsCode, /report\.is_huge_rumor === 'boolean'/);
  assert.match(mergeReportsNode.parameters.query, /payload->>'extraction_confidence'/);
  const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
  const runQwenParser = new AsyncFunction('$input', '$', qwenParserNode.parameters.jsCode);
  const request = { json: { raw_post_id: '1', external_post_id: '2', post_url: 'https://x.com/test/status/2', posted_at: '2026-08-27T00:00:00.000Z', source: source('test') } };
  const parseQwen = (report) => runQwenParser({ all: () => [{ json: { choices: [{ message: { content: JSON.stringify({ transfer_related: true, reports: [report] }) } }] }, pairedItem: { item: 0 } }] }, () => ({ all: () => [request] }));
  const parsedEvidence = await parseQwen(evidenceReport({ extraction_confidence: 0.84 }));
  assert.equal(parsedEvidence[0].json.valid, true);
  assert.equal(parsedEvidence[0].json.report.extraction_confidence, 0.84);
  assert.equal((await parseQwen(validReport()))[0].json.valid, false);
  const runMerge = new AsyncFunction('$input', mergeExtractedNode.parameters.jsCode);
  const preferredEvidence = evidenceReport({
    stage_signal: 'talks', claim_stance: 'supports', wording_strength: 'direct', club_agreement_state: 'talks', personal_terms_state: 'talks',
    completion_claim: 'none', attribution_kind: 'original', named_originator: null, extraction_confidence: 0.55,
  });
  const lowerRankedEvidence = evidenceReport({
    stage_signal: 'done', claim_stance: 'contradicts', wording_strength: 'definitive', club_agreement_state: 'agreed', personal_terms_state: 'agreed',
    completion_claim: 'reporter_done', attribution_kind: 'cites_named_source', named_originator: 'David Ornstein', extraction_confidence: 0.95,
  });
  const mergedEvidence = await runMerge({ all: () => [
    { json: { report: { ...preferredEvidence, raw_post_id: '1', post_url: 'https://x.com/preferred/status/1', posted_at: '2026-08-27T00:00:00.000Z', source: { priority_rank: 1, reliability_score: 0.9 } } } },
    { json: { report: { ...lowerRankedEvidence, raw_post_id: '2', post_url: 'https://x.com/lower/status/2', posted_at: '2026-08-27T00:01:00.000Z', source: { priority_rank: 4, reliability_score: 0.7 } } } },
  ] });
  const mergedPayload = JSON.parse(mergedEvidence[0].json.params[0]);
  const mergedSnapshot = mergedPayload.snapshot;
  for (const field of ['stage_signal', 'claim_stance', 'wording_strength', 'club_agreement_state', 'personal_terms_state', 'completion_claim', 'attribution_kind', 'named_originator', 'extraction_confidence']) {
    assert.deepEqual(mergedSnapshot[field], preferredEvidence[field], field);
    assert.deepEqual(mergedPayload.normalized_data.conflicts[field], [preferredEvidence[field], lowerRankedEvidence[field]], `${field} conflict`);
  }
  for (const [field, value] of [
    ['player_name', ''],
    ['player_identity_hint', 42],
    ['classification', 'maybe'],
    ['move_type', 'teleport'],
    ['fee_amount', 'many'],
    ['add_ons_amount', -1],
    ['fee_currency', 'eur'],
    ['contract_length_months', 1.5],
    ['contract_expires_on', 'next year'],
    ['has_option_to_buy', 'yes'],
    ['sell_on_percentage', 101],
    ['medical_status', 'whatever'],
    ['agreement_status', 'whatever'],
    ['is_digest_worthy', 'yes'],
  ]) {
    assert.equal((await parseQwen(evidenceReport({ [field]: value })))[0].json.valid, false, field);
  }
  assert.doesNotMatch(workflow.nodes.find((node) => node.name === 'Prepare delivery finalization').parameters.jsCode, /itemMatching/);
  assert.match(sampleNode.parameters.jsCode, /TEST DATA/);
  assert.ok(workflow.connections['Manual sample run']);
  assert.equal(workflow.connections['Select X collector'].main[0][0].node, 'Build twscrape collect request');
  assert.match(reserveNode.parameters.query, /status = 'sending'/);
  assert.doesNotMatch(reserveNode.parameters.query, /sending AS/);
  assert.match(reserveNode.parameters.query, /payload->'discord_payload'/);
  assert.doesNotMatch(reserveNode.parameters.query, /request_payload = EXCLUDED/);
  assert.match(reserveNode.parameters.query, /RETURNING id, status, request_payload/);
  assert.match(deliveryRequestNode.parameters.jsCode, /\$json\.request_payload/);
  assert.doesNotMatch(deliveryRequestNode.parameters.jsCode, /Build bounded Discord digest/);
  assert.match(candidatesNode.parameters.query, /pending_candidates/);
  assert.match(candidatesNode.parameters.query, /dd\.request_payload AS pending_request_payload/);
  assert.match(candidatesNode.parameters.query, /current_player_enrichment/);
  assert.match(candidatesNode.parameters.query, /CASE WHEN \$4::text = 'active'\s+THEN project_transfer_fee_context\(\s*CURRENT_TIMESTAMP, \$1::timestamptz, \$2::timestamptz\s*\) ELSE 0 END/);
  assert.match(candidatesNode.parameters.query, /CASE WHEN \$4::text = 'active' THEN/);
  assert.match(candidatesNode.parameters.query, /'canonical_name'/);
  assert.match(candidatesNode.parameters.query, /'current_club_name'/);
  assert.match(candidatesNode.parameters.query, /'goals'/);
  assert.match(candidatesNode.parameters.query, /'statistics'/);
  assert.match(candidatesNode.parameters.query, /current\.season_state = 'latest_completed'/);
  assert.match(candidatesNode.parameters.query, /DISTINCT ON \(transfer_report_id\)/);
  assert.match(candidatesNode.parameters.query, /r\.created_at >= \$1::timestamptz/);
  assert.match(candidatesNode.parameters.query, /r\.created_at <= \$2::timestamptz/);
  assert.match(candidatesNode.parameters.query, /sent_delivery\.sent_at >= CURRENT_TIMESTAMP - interval '7 days'/);
  assert.match(contextNode.parameters.query, /SELECT DISTINCT value::text::bigint AS transfer_report_id/);
  assert.match(contextNode.parameters.query, /requested_input\.transfer_report_id = tr\.id/);
  assert.match(contextNode.parameters.query, /true AS is_current_request/);
  assert.match(contextNode.parameters.query, /false AS is_current_request/);
  assert.match(contextNode.parameters.query, /UNION ALL/);
  assert.match(contextNode.parameters.query, /LIMIT 25/);
  assert.match(contextNode.parameters.query, /IS DISTINCT FROM 'identity-v9'/);
  assert.match(contextNode.parameters.query, /season\.season_state = 'latest_completed'/);
  assert.match(requestNode.parameters.jsCode, /is_current_request !== false/);
  assert.match(requestNode.parameters.jsCode, /enrichment_player_aliases/);
  assert.match(persistEnrichmentNode.parameters.query, /resolver_version/);
  assert.match(candidatesNode.parameters.query, /'sent_history'::text AS row_type/);
  assert.match(candidatesNode.parameters.query, /r\.snapshot->>'probability_status' IS DISTINCT FROM 'active_scored'/);
  assert.match(candidatesNode.parameters.query, /\$3::text = 'active'/);
  assert.match(candidatesNode.parameters.query, /CASE WHEN \$4::text = 'active'/);
  const prepareCandidatesNode = workflow.nodes.find((node) => node.name === 'Prepare digest candidates query');
  assert.match(prepareCandidatesNode.parameters.jsCode, /PROBABILITY_MODE/);
  assert.match(prepareCandidatesNode.parameters.jsCode, /params: \[context\.collection_cutoff_at, context\.collection_started_at, probabilityMode, enrichmentMode\]/);
  assert.match(workflow.nodes.find((node) => node.name === 'Persist merged reports and revisions').parameters.query, /is_preferred = false/);
  assert.ok(workflow.nodes.find((node) => node.name === 'Clear preferred report source'));
  assert.ok(workflow.nodes.find((node) => node.name === 'Set preferred report source'));
  assert.equal(workflow.connections['Persist merged reports and revisions'].main[0][0].node, 'Prepare merged processed-post Redis write');
  assert.equal(workflow.connections['Resume merged processing after Redis'].main[0][0].node, 'Prepare preferred source reset');
  assert.equal(workflow.connections['Set preferred report source'].main[0][0].node, 'Prepare enrichment batch query');
  assert.equal(workflow.connections['Prepare enrichment batch query'].main[0][0].node, 'Enrichment enabled?');
  assert.equal(workflow.connections['Enrichment enabled?'].main[1][0].node, 'Prepare digest candidates query');
  assert.equal(workflow.connections['Refresh required?'].main[1][0].node, 'Prepare digest candidates query');
  assert.equal(workflow.connections['Persist soccerdata enrichment result'].main[0][0].node, 'Prepare digest candidates query');
  assert.equal(contextNode.continueOnFail, true);
  assert.match(contextNode.parameters.query, /is_digest_worthy/);
  assert.match(contextNode.parameters.query, /source_priority_rank/);
  assert.match(contextNode.parameters.query, /source_reliability_score/);
  assert.match(contextNode.parameters.query, /force_resolver_retry/);
  assert.match(contextNode.parameters.query, /LIMIT 25/);
  assert.equal(persistEnrichmentNode.continueOnFail, true);
  assert.equal(enrichNode.continueOnFail, true);
  assert.equal(enrichNode.retryOnFail, undefined);
  assert.equal(enrichNode.parameters.options.timeout, 85000);
  assert.match(persistEnrichmentNode.parameters.query, /JOIN provider_ids provider_id/);
  assert.match(persistEnrichmentNode.parameters.query, /\|\| \(expanded\.item->>'item_key'\) \|\| ':' \|\|/);
  assert.match(persistEnrichmentNode.parameters.query, /jsonb_typeof\(item->'profile'\) = 'object'/);
  assert.match(persistEnrichmentNode.parameters.query, /jsonb_typeof\(item->'statistics'\) = 'object'/);
  assert.match(persistEnrichmentNode.parameters.query, /'candidate_count'/);
  assert.match(persistEnrichmentNode.parameters.query, /'candidates'/);
  assert.match(persistEnrichmentNode.parameters.query, /'resolver_version', expanded\.item->>'resolver_version'/);
  assert.match(persistEnrichmentNode.parameters.query, /HAVING count\(DISTINCT provider_competition_id\) = 1/);
  assert.doesNotMatch(persistEnrichmentNode.parameters.query, /item->'profile' IS NOT NULL/);
  assert.doesNotMatch(persistEnrichmentNode.parameters.query, /item->'statistics' IS NOT NULL/);
  assert.match(mergeReportsNode.parameters.query, /transfer_report_player_resolutions/);
  assert.equal(workflow.connections['Prepare digest candidates query'].main[0][0].node, 'Find undelivered revisions');
  assert.match(digestNode.parameters.jsCode, /pending_idempotency_key/);
  assert.match(digestNode.parameters.jsCode, /typeof snapshot\.classification !== 'string'/);
  assert.match(requestNode.parameters.jsCode, /current_club_name: typeof canonicalCurrentClub === 'string'/);
  assert.match(requestNode.parameters.jsCode, /destination_club_name: destinationEligible && typeof canonicalDestinationClub === 'string'/);
  assert.match(requestNode.parameters.jsCode, /const destinationClubKey = namedContext\(canonicalDestinationClub\);/);
  assert.doesNotMatch(requestNode.parameters.jsCode, /\['official_confirmed', 'loan'\]\.includes\(context\.classification\)/);
  assert.equal(runNode.parameters.options.queryReplacement, '={{ $json.params }}');
  assert.equal(recoveryNode.parameters.options.queryReplacement, undefined);
  assert.equal(
    workflow.nodes.find((node) => node.name === 'Set preferred report source').parameters.options.queryReplacement,
    '={{ [$json.transfer_report_id, $json.preferred_raw_post_id] }}',
  );
  assert.equal(workflow.settings.timezone, 'Asia/Ho_Chi_Minh');
});
