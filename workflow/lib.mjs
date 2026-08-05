import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';

export const CLASSIFICATIONS = Object.freeze([
  'official_confirmed',
  'advanced_negotiations',
  'rumor',
  'rejected_failed',
  'contract_renewal',
  'loan',
]);

export const MOVE_TYPES = Object.freeze(['permanent', 'loan', 'unknown']);
export const MEDICAL_STATES = Object.freeze([
  'not_reported', 'scheduled', 'passed', 'failed', 'pending', 'unknown',
]);
export const AGREEMENT_STATES = Object.freeze([
  'not_reported', 'reached', 'close', 'negotiating', 'rejected', 'unknown',
]);

const REPORT_FIELDS = Object.freeze([
  'player_name',
  'player_identity_hint',
  'current_club_name',
  'destination_club_name',
  'classification',
  'move_type',
  'fee_amount',
  'fee_currency',
  'add_ons_amount',
  'add_ons_currency',
  'release_clause_amount',
  'release_clause_currency',
  'contract_length_months',
  'contract_expires_on',
  'loan_ends_on',
  'has_option_to_buy',
  'has_obligation_to_buy',
  'sell_on_percentage',
  'medical_status',
  'agreement_status',
  'is_huge_rumor',
  'is_digest_worthy',
  'confidence',
]);

const CLASSIFICATION_PRECEDENCE = Object.freeze({
  contract_renewal: 6,
  rejected_failed: 5,
  loan: 4,
  official_confirmed: 3,
  advanced_negotiations: 2,
  rumor: 1,
});

const OFFICIAL_USERNAMES = new Set(['realmadrid', 'manutd']);
const TIER_TWO_USERNAMES = new Set(['david_ornstein', 'fabrizioromano']);
const ISO_DATE = /^\d{4}-\d{2}-\d{2}$/;
const ISO_CURRENCY = /^[A-Z]{3}$/;
const DECIMAL_ID = /^\d+$/;

export function normalizeText(value) {
  return String(value ?? '')
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, ' ')
    .trim()
    .replace(/\s+/g, ' ');
}

export function normalizeIdentity(value) {
  return normalizeText(value).replace(/\s/g, '-');
}

const EMPTY_ENTITY_ALIASES = Object.freeze({ clubs: Object.freeze({}), players: Object.freeze({}), sibling_groups: Object.freeze([]) });

function aliasMap(entries, label) {
  if (!Array.isArray(entries)) throw new Error(`${label} aliases must be an array`);
  const aliases = {};
  for (const entry of entries) {
    if (!entry || typeof entry !== 'object' || typeof entry.canonical !== 'string' || !entry.canonical.trim() || !Array.isArray(entry.aliases) || !entry.aliases.every((alias) => typeof alias === 'string' && alias.trim())) {
      throw new Error(`Invalid ${label} alias entry`);
    }
    for (const name of [entry.canonical, ...entry.aliases]) {
      const key = normalizeText(name);
      if (aliases[key] && aliases[key] !== entry.canonical) throw new Error(`Conflicting ${label} alias: ${name}`);
      aliases[key] = entry.canonical;
    }
  }
  return Object.freeze(aliases);
}

export function parseEntityAliases(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Entity aliases must be an object');
  if (!Array.isArray(value.sibling_groups) || !value.sibling_groups.every((group) => Array.isArray(group) && group.length >= 2 && group.every((name) => typeof name === 'string' && name.trim()))) {
    throw new Error('Sibling groups must contain at least two player names');
  }
  return Object.freeze({
    clubs: aliasMap(value.clubs, 'club'),
    players: aliasMap(value.players, 'player'),
    sibling_groups: Object.freeze(value.sibling_groups.map((group) => Object.freeze([...group]))),
  });
}

export async function loadEntityAliases(path) {
  return parseEntityAliases(JSON.parse(await readFile(path, 'utf8')));
}

export function canonicalizeReport(report, entityAliases = EMPTY_ENTITY_ALIASES) {
  const canonical = (value, aliases) => typeof value === 'string' ? aliases[normalizeText(value)] ?? value.trim() : value;
  return {
    ...report,
    player_name: canonical(report.player_name, entityAliases.players),
    current_club_name: canonical(report.current_club_name, entityAliases.clubs),
    destination_club_name: canonical(report.destination_club_name, entityAliases.clubs),
  };
}

export function enrichmentMode(value) {
  return ['shadow', 'active'].includes(String(value ?? '').trim().toLowerCase())
    ? String(value).trim().toLowerCase()
    : 'off';
}

export function enrichmentUnicodeKey(value) {
  return String(value ?? '')
    .normalize('NFKC')
    .toLocaleLowerCase('und')
    .replace(/[\p{P}\p{Z}]+/gu, ' ')
    .trim()
    .replace(/\s+/gu, ' ');
}

function enrichmentNamedContext(value) {
  const normalized = enrichmentUnicodeKey(value);
  return normalized && !/^(not reported|unknown|n a)$/u.test(normalized) ? normalized : null;
}

function enrichmentFresh(value, now) {
  const timestamp = Date.parse(String(value ?? ''));
  return Number.isFinite(timestamp) && timestamp > now;
}

export function buildEnrichmentRequest(contexts, {
  mode,
  requestId,
  now = Date.now(),
  maximumItems = 25,
} = {}) {
  const selectedMode = enrichmentMode(mode);
  if (selectedMode === 'off') return { mode: 'off', refreshRequired: false, request: null };

  const groups = new Map();
  for (const context of Array.isArray(contexts) ? contexts : []) {
    const reportId = String(context?.transfer_report_id ?? '');
    const reportedName = typeof context?.reported_player_name === 'string'
      ? context.reported_player_name.trim()
      : '';
    const knownProviderId = String(context?.provider_player_id ?? '');
    if (!/^\d+$/.test(reportId) || !reportedName || (knownProviderId && !DECIMAL_ID.test(knownProviderId))) continue;

    const overrides = Array.isArray(context.identity_overrides) ? context.identity_overrides : [];
    const latestStatus = String(context.latest_attempt_status ?? '');
    const latestStartedAt = Date.parse(String(context.latest_attempt_started_at ?? ''));
    const retryAt = Date.parse(String(context.latest_attempt_next_retry_at ?? ''));
    if (
      (Number.isFinite(retryAt) && retryAt > now)
      || (!knownProviderId && overrides.length === 0
        && ['ambiguous', 'unresolved'].includes(latestStatus)
        && Number.isFinite(latestStartedAt)
        && latestStartedAt > now - 24 * 60 * 60 * 1000)
    ) continue;

    const profileFresh = enrichmentFresh(context.profile_fresh_until, now);
    const statisticsFresh = enrichmentFresh(context.statistics_fresh_until, now);
    if (
      knownProviderId
      && profileFresh
      && (
        statisticsFresh
        || context.profile_current_provider_team_id === null
        || latestStatus === 'unattached'
      )
    ) continue;

    const currentClubKey = enrichmentNamedContext(context.current_club_name);
    const destinationClubKey = ['official_confirmed', 'loan'].includes(context.classification)
      || context.move_type === 'loan'
      ? enrichmentNamedContext(context.destination_club_name)
      : null;
    const clubKey = currentClubKey ?? destinationClubKey;
    if (!knownProviderId && !clubKey) continue;

    const reportedNameKey = enrichmentUnicodeKey(reportedName);
    if (!knownProviderId && !reportedNameKey) continue;
    const itemKey = knownProviderId
      ? `provider:${knownProviderId}`
      : `name:${reportedNameKey}|club:${clubKey}`;
    const existing = groups.get(itemKey);
    if (existing) {
      existing.report_ids.push(reportId);
      for (const alias of Array.isArray(context.aliases) ? context.aliases : []) {
        if (typeof alias === 'string' && alias.trim() && !existing.aliases.includes(alias.trim())) {
          existing.aliases.push(alias.trim());
        }
      }
      for (const override of overrides) {
        if (!existing.identity_overrides.some((candidate) => JSON.stringify(candidate) === JSON.stringify(override))) {
          existing.identity_overrides.push(override);
        }
      }
      continue;
    }

    groups.set(itemKey, {
      item_key: itemKey,
      reported_name: reportedName,
      known_provider_player_id: knownProviderId || null,
      current_club_name: typeof context.current_club_name === 'string'
        ? context.current_club_name.trim()
        : null,
      report_ids: [reportId],
      aliases: [...new Set((Array.isArray(context.aliases) ? context.aliases : [])
        .filter((alias) => typeof alias === 'string' && alias.trim())
        .map((alias) => alias.trim()))],
      identity_overrides: overrides,
      team_mapping: context.team_mapping_fresh === true && context.team_mapping
        ? context.team_mapping
        : null,
      season_mapping: context.season_mapping_fresh === true && context.season_mapping
        ? context.season_mapping
        : null,
      request_context: {
        reported_name_key: reportedNameKey,
        current_club_key: currentClubKey,
        destination_club_key: destinationClubKey,
      },
    });
  }

  const players = [...groups.values()].slice(0, maximumItems);
  return {
    mode: selectedMode,
    refreshRequired: players.length > 0,
    request: players.length > 0 ? {
      request_id: String(requestId ?? ''),
      deadline_ms: 75_000,
      players,
    } : null,
  };
}

const ENRICHMENT_STATUSES = new Set([
  'cache_hit', 'fresh', 'partial', 'unresolved', 'ambiguous', 'deferred',
  'provider_failure', 'rate_limited', 'timeout', 'schema_failure',
  'unsupported_competition', 'missing_season', 'club_conflict', 'unattached',
]);

function enrichmentFailure(player, code = 'service_contract_invalid') {
  return {
    item_key: player.item_key,
    report_ids: player.report_ids,
    request_context: player.request_context ?? {},
    status: 'schema_failure',
    retryable: true,
    provider_calls: 0,
    cache_hits: 0,
    identity: null,
    profile: null,
    statistics: null,
    candidates: [],
    error: { code },
  };
}

function normalizeEnrichmentCandidates(candidates) {
  if (!Array.isArray(candidates)) return [];
  const normalized = [];
  for (const candidate of candidates) {
    const providerPlayerId = typeof candidate?.provider_player_id === 'string'
      ? candidate.provider_player_id
      : '';
    const canonicalName = typeof candidate?.canonical_name === 'string'
      ? candidate.canonical_name.trim()
      : '';
    if (
      !DECIMAL_ID.test(providerPlayerId)
      || !canonicalName
      || typeof candidate?.score !== 'number'
      || !Number.isFinite(candidate.score)
      || candidate.score < 0
      || candidate.score > 100
    ) continue;
    normalized.push({
      provider_player_id: providerPlayerId,
      canonical_name: canonicalName,
      score: candidate.score,
    });
    if (normalized.length === 5) break;
  }
  return normalized;
}

function enrichmentHash(value) {
  return createHash('sha256').update(JSON.stringify(value ?? {})).digest('hex');
}

export function normalizeEnrichmentResponse(request, response) {
  const players = Array.isArray(request?.players) ? request.players : [];
  const failAll = (code) => ({
    request_id: String(request?.request_id ?? ''),
    items: players.map((player) => enrichmentFailure(player, code)),
  });
  if (!request || typeof request.request_id !== 'string' || players.length === 0) {
    return failAll('invalid_enrichment_request');
  }

  const statusCode = Number(
    response?.statusCode ?? (typeof response?.status === 'number' ? response.status : 200),
  );
  if (!Number.isFinite(statusCode) || statusCode < 200 || statusCode > 299 || response?.error) {
    return failAll('enrichment_service_failed');
  }
  let body = response?.body ?? response;
  try {
    if (typeof body === 'string') body = JSON.parse(body);
  } catch {
    return failAll('enrichment_response_not_json');
  }
  if (
    !body
    || typeof body !== 'object'
    || body.request_id !== request.request_id
    || !Array.isArray(body.items)
  ) return failAll('service_contract_invalid');

  const byKey = new Map();
  for (const item of body.items) {
    if (!item || typeof item !== 'object' || typeof item.item_key !== 'string' || byKey.has(item.item_key)) {
      return failAll('service_contract_invalid');
    }
    byKey.set(item.item_key, item);
  }

  return {
    request_id: request.request_id,
    items: players.map((player) => {
      const item = byKey.get(player.item_key);
      if (!item || !ENRICHMENT_STATUSES.has(item.status)) return enrichmentFailure(player);
      const identity = item.identity;
      const providerPlayerId = String(identity?.provider_player_id ?? '');
      if (identity !== null && (
        !identity
        || identity.provider !== 'sofascore'
        || !DECIMAL_ID.test(providerPlayerId)
      )) return enrichmentFailure(player);
      if (
        ['fresh', 'cache_hit', 'partial'].includes(item.status)
        && (!identity || !item.profile || typeof item.profile !== 'object')
      ) return enrichmentFailure(player);
      if (
        ['fresh', 'cache_hit'].includes(item.status)
        && (!item.statistics || typeof item.statistics !== 'object')
      ) return enrichmentFailure(player);
      if (
        item.profile
        && (
          !Number.isFinite(Date.parse(String(item.profile.retrieved_at ?? '')))
          || (item.profile.current_club !== null && (
            typeof item.profile.current_club !== 'object'
            || !DECIMAL_ID.test(String(item.profile.current_club.provider_team_id ?? ''))
            || typeof item.profile.current_club.name !== 'string'
            || !item.profile.current_club.name.trim()
          ))
          || (item.profile.market_value_currency !== null
            && item.profile.market_value_currency !== undefined
            && !ISO_CURRENCY.test(String(item.profile.market_value_currency)))
        )
      ) return enrichmentFailure(player);
      if (
        item.statistics
        && (
          !DECIMAL_ID.test(String(item.statistics.provider_unique_tournament_id ?? ''))
          || !DECIMAL_ID.test(String(item.statistics.provider_season_id ?? ''))
          || !['active', 'latest_completed'].includes(item.statistics.season_state)
          || item.statistics.scope !== 'selected_domestic_league_all_clubs'
          || !Number.isFinite(Date.parse(String(item.statistics.retrieved_at ?? '')))
        )
      ) return enrichmentFailure(player);

      const rawPayloads = item.provenance?.raw_payloads;
      const rawProfile = rawPayloads?.profile && typeof rawPayloads.profile === 'object'
        ? rawPayloads.profile
        : {};
      const rawStatistics = rawPayloads?.statistics && typeof rawPayloads.statistics === 'object'
        ? rawPayloads.statistics
        : {};
      const cacheHits = Number(item.provenance?.profile_cache === 'hit')
        + Number(item.provenance?.statistics_cache === 'hit');
      return {
        item_key: player.item_key,
        report_ids: player.report_ids,
        request_context: player.request_context ?? {},
        status: item.status,
        retryable: item.error?.retryable === true
          || (Array.isArray(item.warnings) && item.warnings.some((warning) => warning?.retryable === true)),
        provider_calls: Number.isInteger(item.provider_calls) && item.provider_calls >= 0
          ? item.provider_calls
          : 0,
        cache_hits: cacheHits,
        identity: identity ? {
          provider: 'sofascore',
          provider_player_id: providerPlayerId,
          stable_source_identifier: String(identity.stable_source_identifier ?? `sofascore:player:${providerPlayerId}`),
          canonical_name: typeof item.profile?.canonical_name === 'string'
            ? item.profile.canonical_name
            : player.reported_name,
          score: Number.isFinite(identity.score) ? identity.score : null,
          margin: Number.isFinite(identity.margin) ? identity.margin : null,
          resolver_version: typeof identity.resolver_version === 'string' && identity.resolver_version
            ? identity.resolver_version
            : 'identity-v1',
        } : null,
        profile: item.profile && typeof item.profile === 'object' ? {
          ...item.profile,
          content_sha256: enrichmentHash(item.profile),
          raw_sha256: enrichmentHash(rawProfile),
          raw_cache_key: providerPlayerId ? `profile-${providerPlayerId}` : null,
          raw_payload: rawProfile,
        } : null,
        statistics: item.statistics && typeof item.statistics === 'object' ? {
          ...item.statistics,
          content_sha256: enrichmentHash(item.statistics),
          raw_sha256: enrichmentHash(rawStatistics),
          raw_cache_key: providerPlayerId
            ? `statistics-${providerPlayerId}-${item.statistics.provider_unique_tournament_id}-${item.statistics.provider_season_id}`
            : null,
          raw_payload: rawStatistics,
        } : null,
        candidates: normalizeEnrichmentCandidates(item.candidates),
        warning_codes: Array.isArray(item.warnings)
          ? item.warnings.map((warning) => String(warning?.code ?? '')).filter(Boolean)
          : [],
        error: item.error && typeof item.error === 'object'
          ? { code: String(item.error.code ?? 'enrichment_failed').slice(0, 100) }
          : null,
      };
    }),
  };
}

export function parseSourceRegistry(markdown) {
  let accountType = null;
  const accounts = [];
  const seenIds = new Set();
  const lines = String(markdown).split(/\r?\n/);

  for (const line of lines) {
    if (/^##\s+Individuals/i.test(line)) {
      accountType = 'individual';
      continue;
    }
    if (/^##\s+Organizations/i.test(line)) {
      accountType = 'organization';
      continue;
    }
    if (!accountType || !line.trimStart().startsWith('|')) continue;

    const cells = line.split('|').slice(1, -1).map((cell) => cell.trim());
    if (cells.length !== 4 || /^(name|organization)$/i.test(cells[0]) || /^-+$/.test(cells[0].replace(/\s/g, ''))) continue;
    const username = cells[1].replace(/`/g, '').replace(/^@/, '').trim();
    const externalAccountId = cells[3].replace(/`/g, '').trim();
    if (!/^[A-Za-z0-9_]{1,15}$/.test(username)) {
      throw new Error(`Invalid X username for ${cells[0]}: ${username}`);
    }
    if (!DECIMAL_ID.test(externalAccountId)) {
      throw new Error(`Invalid decimal X ID for @${username}: ${externalAccountId}`);
    }
    if (seenIds.has(externalAccountId)) {
      throw new Error(`Duplicate X ID in source registry: ${externalAccountId}`);
    }
    seenIds.add(externalAccountId);
    accounts.push(sourceMetadata({
      display_name: cells[0],
      username,
      external_account_id: externalAccountId,
      account_type: accountType,
    }));
  }

  if (accounts.length !== 78) {
    throw new Error(`Expected 78 source accounts, found ${accounts.length}`);
  }
  return accounts;
}

export async function loadSourceRegistry(path) {
  return parseSourceRegistry(await readFile(path, 'utf8'));
}

export function sourceMetadata(account) {
  const username = String(account.username).replace(/^@/, '');
  const lower = username.toLowerCase();
  let priority_rank = 4;
  let reliability_score = 0.70;
  let is_official = false;
  if (OFFICIAL_USERNAMES.has(lower)) {
    priority_rank = 1;
    reliability_score = 1.00;
    is_official = true;
  } else if (TIER_TWO_USERNAMES.has(lower)) {
    priority_rank = 2;
    reliability_score = 0.95;
  } else if (account.account_type === 'organization') {
    priority_rank = 3;
    reliability_score = 0.80;
  }
  return {
    platform: 'x',
    external_account_id: String(account.external_account_id),
    username,
    display_name: String(account.display_name),
    account_type: account.account_type,
    is_official,
    priority_rank,
    reliability_score,
  };
}

function legacyText(tweet) {
  return tweet?.note_tweet?.note_tweet_results?.result?.text
    ?? tweet?.legacy?.full_text
    ?? tweet?.legacy?.text
    ?? null;
}

function tweetId(tweet) {
  return String(tweet?.rest_id ?? tweet?.legacy?.id_str ?? tweet?.id_str ?? '');
}

function quotedText(tweet) {
  const quoted = tweet?.quoted_status_result?.result
    ?? tweet?.legacy?.quoted_status_result?.result
    ?? null;
  return legacyText(quoted);
}

function isPureRetweet(tweet, text) {
  return Boolean(
    tweet?.legacy?.retweeted_status_result
    || tweet?.retweeted_status_result
    || /^RT\s+@/i.test(text ?? ''),
  );
}

function findTweets(value, found, seenObjects) {
  if (!value || typeof value !== 'object' || seenObjects.has(value)) return;
  seenObjects.add(value);
  const text = legacyText(value);
  const id = tweetId(value);
  if (id && text) found.push(value);
  for (const child of Object.values(value)) {
    if (child && typeof child === 'object') findTweets(child, found, seenObjects);
  }
}

export function parseRapidApiPosts(payload, source) {
  const candidates = [];
  findTweets(payload, candidates, new Set());
  const posts = [];
  const seenIds = new Set();
  for (const tweet of candidates) {
    const external_post_id = tweetId(tweet);
    const content = legacyText(tweet)?.trim();
    if (!DECIMAL_ID.test(external_post_id) || !content || seenIds.has(external_post_id)) continue;
    seenIds.add(external_post_id);
    if (isPureRetweet(tweet, content)) continue;
    const rawDate = tweet?.legacy?.created_at ?? tweet?.created_at;
    const parsedDate = rawDate ? new Date(rawDate) : null;
    if (!parsedDate || Number.isNaN(parsedDate.valueOf())) continue;
    const quote = quotedText(tweet);
    posts.push({
      platform: 'x',
      external_post_id,
      post_url: `https://x.com/${source.username}/status/${external_post_id}`,
      content: quote ? `${content}\n\nQuoted post:\n${quote}` : content,
      posted_at: parsedDate.toISOString(),
      source,
      is_quote: Boolean(quote),
      raw_payload: tweet,
    });
  }
  return posts.sort((a, b) => a.posted_at.localeCompare(b.posted_at));
}

function isNullableString(value) {
  return value === null || typeof value === 'string';
}

function isNullableNumber(value) {
  return value === null || (typeof value === 'number' && Number.isFinite(value));
}

function isNullableBoolean(value) {
  return value === null || typeof value === 'boolean';
}

function isNullableInteger(value) {
  return value === null || (Number.isInteger(value) && value > 0);
}

function isNullableDate(value) {
  return value === null || (typeof value === 'string' && ISO_DATE.test(value));
}

function isNullableCurrency(value) {
  return value === null || (typeof value === 'string' && ISO_CURRENCY.test(value));
}

export function validateQwenResponse(value) {
  const errors = [];
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    return { valid: false, errors: ['response must be an object'] };
  }
  const expected = new Set(['transfer_related', 'reports']);
  for (const key of Object.keys(value)) if (!expected.has(key)) errors.push(`unexpected response property: ${key}`);
  for (const key of expected) if (!(key in value)) errors.push(`missing response property: ${key}`);
  if (typeof value.transfer_related !== 'boolean') errors.push('transfer_related must be boolean');
  if (!Array.isArray(value.reports)) errors.push('reports must be an array');
  if (value.transfer_related === false && Array.isArray(value.reports) && value.reports.length) errors.push('non-transfer responses cannot include reports');
  if (Array.isArray(value.reports)) {
    value.reports.forEach((report, index) => {
      const label = `reports[${index}]`;
      if (!report || typeof report !== 'object' || Array.isArray(report)) {
        errors.push(`${label} must be an object`);
        return;
      }
      const keys = new Set(Object.keys(report));
      for (const field of REPORT_FIELDS) if (!keys.has(field)) errors.push(`${label}.${field} is required`);
      for (const field of keys) if (!REPORT_FIELDS.includes(field)) errors.push(`${label}.${field} is not allowed`);
      if (typeof report.player_name !== 'string' || !report.player_name.trim()) errors.push(`${label}.player_name must be non-empty string`);
      for (const field of ['player_identity_hint', 'current_club_name', 'destination_club_name']) {
        if (!isNullableString(report[field])) errors.push(`${label}.${field} must be string or null`);
      }
      if (!CLASSIFICATIONS.includes(report.classification)) errors.push(`${label}.classification is invalid`);
      if (!MOVE_TYPES.includes(report.move_type)) errors.push(`${label}.move_type is invalid`);
      for (const field of ['fee_amount', 'add_ons_amount', 'release_clause_amount', 'sell_on_percentage']) {
        if (!isNullableNumber(report[field]) || (report[field] !== null && report[field] < 0)) errors.push(`${label}.${field} must be non-negative number or null`);
      }
      for (const field of ['fee_currency', 'add_ons_currency', 'release_clause_currency']) {
        if (!isNullableCurrency(report[field])) errors.push(`${label}.${field} must be ISO currency or null`);
      }
      if (!isNullableInteger(report.contract_length_months)) errors.push(`${label}.contract_length_months must be positive integer or null`);
      for (const field of ['contract_expires_on', 'loan_ends_on']) {
        if (!isNullableDate(report[field])) errors.push(`${label}.${field} must be ISO date or null`);
      }
      for (const field of ['has_option_to_buy', 'has_obligation_to_buy']) {
        if (!isNullableBoolean(report[field])) errors.push(`${label}.${field} must be boolean or null`);
      }
      if (!MEDICAL_STATES.includes(report.medical_status)) errors.push(`${label}.medical_status is invalid`);
      if (!AGREEMENT_STATES.includes(report.agreement_status)) errors.push(`${label}.agreement_status is invalid`);
      if (typeof report.is_huge_rumor !== 'boolean') errors.push(`${label}.is_huge_rumor must be boolean`);
      if (typeof report.is_digest_worthy !== 'boolean') errors.push(`${label}.is_digest_worthy must be boolean`);
      if (typeof report.confidence !== 'number' || !Number.isFinite(report.confidence) || report.confidence < 0 || report.confidence > 1) errors.push(`${label}.confidence must be between 0 and 1`);
    });
  }
  return { valid: errors.length === 0, errors };
}

export function chooseClassification(classifications) {
  return [...classifications]
    .filter((classification) => CLASSIFICATIONS.includes(classification))
    .sort((left, right) => CLASSIFICATION_PRECEDENCE[right] - CLASSIFICATION_PRECEDENCE[left])[0] ?? 'rumor';
}

export function dedupeKey(report, entityAliases = EMPTY_ENTITY_ALIASES) {
  const canonical = canonicalizeReport(report, entityAliases);
  return [canonical.player_name, canonical.current_club_name || 'unknown', canonical.destination_club_name || 'unknown']
    .map(normalizeIdentity)
    .join('|');
}

export function sourceComparator(left, right) {
  const leftSource = left.source ?? left.preferred_source ?? left;
  const rightSource = right.source ?? right.preferred_source ?? right;
  return (leftSource.priority_rank - rightSource.priority_rank)
    || (rightSource.reliability_score - leftSource.reliability_score)
    || String(left.posted_at ?? '').localeCompare(String(right.posted_at ?? ''))
    || String(left.post_url ?? '').localeCompare(String(right.post_url ?? ''));
}

function firstDefined(reports, field, conflicts) {
  const populated = reports.filter((report) => report[field] !== null && report[field] !== undefined && report[field] !== '');
  if (!populated.length) return null;
  const value = populated[0][field];
  const distinct = [...new Set(populated.map((report) => JSON.stringify(report[field])))];
  if (distinct.length > 1) conflicts[field] = populated.map((report) => report[field]);
  return value;
}

export function mergeReportGroup(group, entityAliases = EMPTY_ENTITY_ALIASES) {
  if (!Array.isArray(group) || !group.length) throw new Error('Cannot merge an empty report group');
  const sorted = group.map((report) => canonicalizeReport(report, entityAliases)).sort(sourceComparator);
  const conflicts = {};
  const merged = {};
  for (const field of REPORT_FIELDS) merged[field] = firstDefined(sorted, field, conflicts);
  merged.player_name = firstDefined(sorted, 'player_name', conflicts) ?? 'Unknown player';
  merged.classification = chooseClassification(sorted.map((report) => report.classification));
  merged.confidence = Math.max(...sorted.map((report) => report.confidence));
  merged.dedupe_key = dedupeKey(merged, entityAliases);
  merged.first_reported_at = sorted.map((report) => report.posted_at).sort()[0];
  merged.last_reported_at = sorted.map((report) => report.posted_at).sort().at(-1);
  merged.preferred_source = sorted[0].source;
  merged.sources = sorted.map((report) => ({
    raw_post_id: report.raw_post_id ?? null,
    post_url: report.post_url,
    posted_at: report.posted_at,
    source: report.source,
  }));
  merged.normalized_data = { conflicts };
  return merged;
}

export function materialSnapshot(report) {
  const snapshot = {};
  for (const field of REPORT_FIELDS) snapshot[field] = report[field] ?? null;
  snapshot.dedupe_key = report.dedupe_key;
  return snapshot;
}

export function hashSnapshot(snapshot) {
  return createHash('sha256').update(JSON.stringify(snapshot)).digest('hex');
}

export function materialRevision(existingHash, report) {
  const snapshot = materialSnapshot(report);
  const materialSnapshotForHash = { ...snapshot };
  delete materialSnapshotForHash.is_digest_worthy;
  const content_sha256 = hashSnapshot(materialSnapshotForHash);
  return { changed: content_sha256 !== existingHash, content_sha256, snapshot };
}

export function retryDelayMs({ attempt, retryAfter, rateResetEpochSeconds, now = Date.now(), maximumMs = 300_000 }) {
  const retryAfterSeconds = Number(retryAfter);
  const rateResetMs = Number(rateResetEpochSeconds) * 1000 - now;
  const headerDelay = Number.isFinite(retryAfterSeconds) && retryAfterSeconds >= 0
    ? retryAfterSeconds * 1000
    : (Number.isFinite(rateResetMs) && rateResetMs >= 0 ? rateResetMs : null);
  const exponential = Math.min(maximumMs, 1000 * (2 ** Math.max(0, Number(attempt) - 1)));
  return Math.min(maximumMs, Math.max(exponential, headerDelay ?? 0));
}

export function shouldRetry(service, statusCode) {
  const status = Number(statusCode);
  if (service === 'discord') return status === 429 || (status >= 500 && status <= 599);
  return status === 429 || (status >= 500 && status <= 599) || status === 0;
}

function classificationWeight(classification) {
  return CLASSIFICATION_PRECEDENCE[classification] ?? 0;
}

function digestPriority(report) {
  if (report.classification === 'official_confirmed') return 0;
  const source = report.preferred_source ?? report.source ?? {};
  const username = String(source.username ?? '').toLowerCase();
  const displayName = normalizeText(source.display_name);
  if (username === 'fabrizioromano' || username === 'david_ornstein' || displayName === 'fabrizio romano' || displayName === 'david ornstein') return 1;
  if (report.classification === 'rumor' && report.is_huge_rumor === true) return 2;
  if (report.classification === 'rumor' && Number(report.fee_amount) >= 70_000_000 && ['EUR', 'GBP'].includes(String(report.fee_currency ?? '').toUpperCase())) return 3;
  return 4;
}

function formatAmount(amount, currency) {
  if (amount === null || amount === undefined) return null;
  return `${Number(amount).toLocaleString('en-US')} ${currency ?? ''}`.trim();
}

function hasNamedClub(value) {
  return typeof value === 'string'
    && value.trim().length > 0
    && !/^(not[ _-]?reported|unknown|n\/?a)$/i.test(value.trim());
}

function digestStoryKey(report) {
  return [report.player_name, report.destination_club_name].map(normalizeIdentity).join('|');
}

function isDigestEligible(report) {
  return report.is_digest_worthy === true
    && hasNamedClub(report.current_club_name)
    && hasNamedClub(report.destination_club_name);
}

const DIGEST_UPDATE_FIELDS = Object.freeze([
  'classification', 'move_type', 'fee_amount', 'fee_currency', 'add_ons_amount', 'add_ons_currency',
  'release_clause_amount', 'release_clause_currency', 'contract_length_months', 'contract_expires_on',
  'loan_ends_on', 'has_option_to_buy', 'has_obligation_to_buy', 'sell_on_percentage', 'medical_status',
  'agreement_status', 'confidence',
]);

function digestMaterialKey(report) {
  return JSON.stringify(Object.fromEntries(DIGEST_UPDATE_FIELDS.map((field) => [field, report[field] ?? null])));
}

function sameDigestStory(left, right) {
  return digestStoryKey(left) === digestStoryKey(right);
}

function isNewDigestUpdate(report, entityAliases, now) {
  const sent = (Array.isArray(report.sent_history) ? report.sent_history : [])
    .filter((entry) => entry && entry.snapshot && entry.sent_at)
    .map((entry) => ({ ...entry, snapshot: canonicalizeReport(entry.snapshot, entityAliases) }))
    .filter((entry) => sameDigestStory(report, entry.snapshot));
  const confirmedWithinCooldown = sent.some((entry) => entry.snapshot.classification === 'official_confirmed'
    && now - Date.parse(entry.sent_at) < 7 * 24 * 60 * 60 * 1000);
  if (report.classification !== 'rejected_failed' && confirmedWithinCooldown) return false;
  return !sent.some((entry) => digestMaterialKey(entry.snapshot) === digestMaterialKey(report));
}

function storyLines(report) {
  const clubDirection = `${report.current_club_name} → ${report.destination_club_name}`;
  const details = [
    `Classification: ${report.classification.replaceAll('_', ' ')}`,
    report.move_type && report.move_type !== 'unknown' ? `Move: ${report.move_type}` : null,
    formatAmount(report.fee_amount, report.fee_currency) ? `Fee: ${formatAmount(report.fee_amount, report.fee_currency)}` : null,
    formatAmount(report.add_ons_amount, report.add_ons_currency) ? `Add-ons: ${formatAmount(report.add_ons_amount, report.add_ons_currency)}` : null,
    formatAmount(report.release_clause_amount, report.release_clause_currency) ? `Release clause: ${formatAmount(report.release_clause_amount, report.release_clause_currency)}` : null,
    report.contract_length_months !== null && report.contract_length_months !== undefined ? `Contract length: ${report.contract_length_months} months` : null,
    report.contract_expires_on ? `Contract expires: ${report.contract_expires_on}` : null,
    report.loan_ends_on ? `Loan ends: ${report.loan_ends_on}` : null,
    report.has_option_to_buy !== null && report.has_option_to_buy !== undefined ? `Option to buy: ${report.has_option_to_buy ? 'Yes' : 'No'}` : null,
    report.has_obligation_to_buy !== null && report.has_obligation_to_buy !== undefined ? `Obligation to buy: ${report.has_obligation_to_buy ? 'Yes' : 'No'}` : null,
    report.sell_on_percentage !== null && report.sell_on_percentage !== undefined ? `Sell-on: ${report.sell_on_percentage}%` : null,
    report.medical_status && !['not_reported', 'unknown'].includes(report.medical_status) ? `Medical: ${report.medical_status}` : null,
    report.agreement_status && !['not_reported', 'unknown'].includes(report.agreement_status) ? `Agreement: ${report.agreement_status}` : null,
  ];
  const source = report.preferred_source?.display_name ?? report.source?.display_name ?? 'Source';
  const sourceUrl = report.sources?.[0]?.post_url ?? report.post_url;
  return [clubDirection, ...details, `Confidence: ${Math.round(report.confidence * 100)}%`, sourceUrl ? `[${source}](${sourceUrl})` : source].filter(Boolean);
}

function truncate(value, maximum) {
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
  return `${result}…`;
}

function finiteNumber(value) {
  if (value === null || value === undefined || value === '') return null;
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function namedEnrichmentValue(value) {
  if (typeof value !== 'string') return null;
  const text = value.trim();
  return text && !/^(unknown|n\/?a|not[ _-]?reported)$/i.test(text) ? text : null;
}

function staleLabel(snapshot, now, maximumAgeMs) {
  if (snapshot?.stale !== true) return '';
  const retrievedAt = Date.parse(String(snapshot.retrieved_at ?? ''));
  const ageMs = now - retrievedAt;
  if (!Number.isFinite(retrievedAt) || ageMs < 0 || ageMs > maximumAgeMs) return null;
  if (ageMs < 60 * 60 * 1000) return 'stale <1h';
  const hours = Math.floor(ageMs / (60 * 60 * 1000));
  return hours >= 48 ? `stale ${Math.floor(hours / 24)}d` : `stale ${hours}h`;
}

function compactValue(value, currency) {
  const amount = finiteNumber(value);
  const code = String(currency ?? '').trim().toUpperCase();
  if (amount === null || amount < 0 || !ISO_CURRENCY.test(code)) return null;
  const units = amount >= 1_000_000
    ? `${Number((amount / 1_000_000).toFixed(1))}m`
    : (amount >= 1_000 ? `${Number((amount / 1_000).toFixed(1))}k` : String(amount));
  const symbols = { EUR: '€', GBP: '£', USD: '$' };
  return symbols[code] ? `${symbols[code]}${units}` : `${units} ${code}`;
}

function integerStatistic(value, label) {
  const number = finiteNumber(value);
  return number === null ? null : `${Math.trunc(number).toLocaleString('en-US')} ${label}`;
}

function decimalStatistic(value, label) {
  const number = finiteNumber(value);
  return number === null ? null : `${number.toFixed(2)} ${label}`;
}

function enrichmentGroups(enrichment, now) {
  if (!enrichment || typeof enrichment !== 'object' || Array.isArray(enrichment)) return [];
  const profile = enrichment.profile && typeof enrichment.profile === 'object' && !Array.isArray(enrichment.profile)
    ? enrichment.profile
    : null;
  const statistics = enrichment.statistics && typeof enrichment.statistics === 'object' && !Array.isArray(enrichment.statistics)
    ? enrichment.statistics
    : null;

  const profileClub = namedEnrichmentValue(profile?.current_club_name);
  const profileStale = profile
    ? staleLabel(profile, now, profileClub ? 72 * 60 * 60 * 1000 : 7 * 24 * 60 * 60 * 1000)
    : null;
  const statisticsStale = statistics
    ? staleLabel(statistics, now, 72 * 60 * 60 * 1000)
    : null;

  const competition = namedEnrichmentValue(statistics?.competition_name);
  const season = namedEnrichmentValue(statistics?.season_label);
  const scope = statistics?.scope === 'selected_domestic_league_all_clubs'
    ? 'selected league, all clubs'
    : null;
  const statisticsValid = Boolean(statistics && statisticsStale !== null && competition && season && scope);
  const primaryStatistics = statisticsValid ? [
    integerStatistic(statistics.appearances, 'app'),
    integerStatistic(statistics.minutes_played, 'min'),
    integerStatistic(statistics.goals, 'G'),
    integerStatistic(statistics.assists, 'A'),
  ].filter(Boolean) : [];
  const statisticsHeader = statisticsValid
    ? `${competition} ${season} · ${scope}${statisticsStale ? ` · ${statisticsStale}` : ''}`
    : null;

  const profileParts = profile && profileStale !== null ? [
    profileClub,
    namedEnrichmentValue(profile.nationality),
    finiteNumber(profile.age) === null ? null : String(Math.trunc(finiteNumber(profile.age))),
    namedEnrichmentValue(profile.primary_position),
    compactValue(profile.market_value, profile.market_value_currency)
      ? `Sofascore value ${compactValue(profile.market_value, profile.market_value_currency)}`
      : null,
  ].filter(Boolean) : [];
  const profileLine = profileParts.length
    ? `Profile${profileStale ? ` · ${profileStale}` : ''}: ${profileParts.join(' · ')}`
    : null;

  const advancedStatistics = statisticsValid ? [
    integerStatistic(statistics.starts, 'starts'),
    finiteNumber(statistics.minutes_per_appearance) === null
      ? null
      : `${Number(finiteNumber(statistics.minutes_per_appearance).toFixed(1))} min/app`,
    decimalStatistic(statistics.expected_goals, 'xG'),
    decimalStatistic(statistics.expected_assists, 'xA'),
    decimalStatistic(statistics.average_rating, 'rating'),
  ].filter(Boolean) : [];

  const profileDetails = profile && profileStale !== null ? [
    namedEnrichmentValue(profile.date_of_birth) ? `Born ${profile.date_of_birth.trim()}` : null,
    finiteNumber(profile.height_cm) === null ? null : `${Math.trunc(finiteNumber(profile.height_cm))} cm`,
    namedEnrichmentValue(profile.preferred_foot) ? `${profile.preferred_foot.trim()} foot` : null,
  ].filter(Boolean) : [];

  const lowerPriorityStatistics = statisticsValid ? [
    integerStatistic(statistics.yellow_cards, 'yellow'),
    integerStatistic(statistics.red_cards, 'red'),
    integerStatistic(statistics.goalkeeper_clean_sheets, 'clean sheets'),
    integerStatistic(statistics.goalkeeper_saves, 'saves'),
  ].filter(Boolean) : [];
  const statisticsContextLine = statisticsHeader && (
    primaryStatistics.length
    || advancedStatistics.length
    || lowerPriorityStatistics.length
    || statisticsStale
  )
    ? (primaryStatistics.length
      ? `${statisticsHeader}: ${primaryStatistics.join(' · ')}`
      : (statisticsStale ? `Last confirmed: ${statisticsHeader}` : statisticsHeader))
    : null;

  return [
    { priority: 1, displayOrder: 2, line: statisticsContextLine },
    { priority: 2, displayOrder: 1, line: profileLine },
    { priority: 3, displayOrder: 3, line: advancedStatistics.length ? `Advanced: ${advancedStatistics.join(' · ')}` : null },
    { priority: 4, displayOrder: 4, line: profileDetails.length ? `Details: ${profileDetails.join(' · ')}` : null },
    { priority: 5, displayOrder: 5, line: lowerPriorityStatistics.length ? `Other: ${lowerPriorityStatistics.join(' · ')}` : null },
  ];
}

export function selectDigestReports(reports, { entityAliases = EMPTY_ENTITY_ALIASES, now = Date.now() } = {}) {
  const sorted = reports
    .map((report) => canonicalizeReport(report, entityAliases))
    .filter((report) => isDigestEligible(report) && isNewDigestUpdate(report, entityAliases, now))
    .sort((left, right) => (
    digestPriority(left) - digestPriority(right)
    || sourceComparator(left, right)
    || classificationWeight(right.classification) - classificationWeight(left.classification)
    || right.confidence - left.confidence
    || String(right.last_reported_at ?? '').localeCompare(String(left.last_reported_at ?? ''))
    ));
  const seenRevisionIds = new Set();
  const seenStoryKeys = new Set();
  const distinct = sorted.filter((report) => {
    const revisionId = String(report.revision_id ?? '');
    const storyKey = digestStoryKey(report);
    if ((revisionId && seenRevisionIds.has(revisionId)) || seenStoryKeys.has(storyKey)) return false;
    if (revisionId) seenRevisionIds.add(revisionId);
    seenStoryKeys.add(storyKey);
    return true;
  });
  const normal = distinct.slice(0, 15);
  const extra = distinct.slice(15).filter((report) => digestPriority(report) < 2).slice(0, 3);
  return [...normal, ...extra];
}

export function buildDiscordDigest(reports, { windowStartedAt, windowEndedAt, entityAliases, now = Date.now() } = {}) {
  const selected = selectDigestReports(reports, { entityAliases, now });
  const range = windowStartedAt && windowEndedAt ? ` (${windowStartedAt} to ${windowEndedAt})` : '';
  const title = truncate(`Football transfer digest${range}`, 256);
  const footerText = (count) => `${count} new material report${count === 1 ? '' : 's'}`;
  const fields = [];
  for (const report of selected) {
    if (fields.length >= 25) break;
    const name = truncate(`${fields.length + 1}. ${report.player_name}`, 256);
    const lines = storyLines(report);
    const value = lines.join('\n');
    const currentCharacters = title.length + footerText(fields.length).length
      + fields.reduce((total, field) => total + field.name.length + field.value.length, 0);
    const candidateCharacters = currentCharacters - footerText(fields.length).length
      + footerText(fields.length + 1).length + name.length + value.length;
    if (value.length > 1024 || candidateCharacters > 6000) continue;
    fields.push({ name, value, inline: false, lines, report });
  }

  let totalCharacters = title.length + footerText(fields.length).length
    + fields.reduce((total, field) => total + field.name.length + field.value.length, 0);
  for (const field of fields) {
    const accepted = [];
    const sourceLine = field.lines.at(-1);
    const transferLines = field.lines.slice(0, -1);
    for (const group of enrichmentGroups(field.report.enrichment, Number(now))) {
      if (!group.line) continue;
      const nextAccepted = [...accepted, group];
      const enrichmentLines = nextAccepted
        .toSorted((left, right) => left.displayOrder - right.displayOrder)
        .map(({ line }) => line);
      const value = [...transferLines, ...enrichmentLines, sourceLine].join('\n');
      const difference = value.length - field.value.length;
      if (value.length > 1024 || totalCharacters + difference > 6000) break;
      accepted.push(group);
    }
    if (accepted.length) {
      const enrichmentLines = accepted
        .toSorted((left, right) => left.displayOrder - right.displayOrder)
        .map(({ line }) => line);
      const value = [...transferLines, ...enrichmentLines, sourceLine].join('\n');
      totalCharacters += value.length - field.value.length;
      field.value = value;
    }
  }

  return {
    allowed_mentions: { parse: [] },
    embeds: [{
      title,
      color: 0x1d9bf0,
      fields: fields.map(({ lines, report, ...field }) => field),
      footer: { text: footerText(fields.length) },
    }],
  };
}

export function recoverInterruptedDelivery(delivery) {
  if (delivery?.status === 'sending') return { ...delivery, status: 'unknown', retryable: false };
  return { ...delivery, retryable: delivery?.status === 'pending' || delivery?.status === 'failed' };
}

export const REPORT_FIELD_NAMES = REPORT_FIELDS;
