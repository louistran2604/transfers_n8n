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

  if (accounts.length !== 77) {
    throw new Error(`Expected 77 source accounts, found ${accounts.length}`);
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

export function dedupeKey(report) {
  return [report.player_identity_hint || report.player_name, report.current_club_name || 'unknown', report.destination_club_name || 'unknown']
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

export function mergeReportGroup(group) {
  if (!Array.isArray(group) || !group.length) throw new Error('Cannot merge an empty report group');
  const sorted = [...group].sort(sourceComparator);
  const conflicts = {};
  const merged = {};
  for (const field of REPORT_FIELDS) merged[field] = firstDefined(sorted, field, conflicts);
  merged.player_name = firstDefined(sorted, 'player_name', conflicts) ?? 'Unknown player';
  merged.classification = chooseClassification(sorted.map((report) => report.classification));
  merged.confidence = Math.max(...sorted.map((report) => report.confidence));
  merged.dedupe_key = dedupeKey(merged);
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
  const content_sha256 = hashSnapshot(snapshot);
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

function storyText(report) {
  const clubDirection = [report.current_club_name, report.destination_club_name].filter(Boolean).join(' → ') || 'Club details not reported';
  const details = [
    report.player_identity_hint ? `Identity: ${report.player_identity_hint}` : null,
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
  return [clubDirection, ...details, `Confidence: ${Math.round(report.confidence * 100)}%`, sourceUrl ? `[${source}](${sourceUrl})` : source].filter(Boolean).join('\n');
}

function truncate(value, maximum) {
  const text = String(value ?? '');
  return text.length <= maximum ? text : `${text.slice(0, Math.max(0, maximum - 1))}…`;
}

export function selectDigestReports(reports) {
  const sorted = [...reports].sort((left, right) => (
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
    const storyKey = String(report.dedupe_key ?? dedupeKey(report));
    if ((revisionId && seenRevisionIds.has(revisionId)) || seenStoryKeys.has(storyKey)) return false;
    if (revisionId) seenRevisionIds.add(revisionId);
    seenStoryKeys.add(storyKey);
    return true;
  });
  const normal = distinct.slice(0, 15);
  const extra = distinct.slice(15).filter((report) => digestPriority(report) < 2).slice(0, 3);
  return [...normal, ...extra];
}

export function buildDiscordDigest(reports, { windowStartedAt, windowEndedAt } = {}) {
  const selected = selectDigestReports(reports);
  const fields = [];
  let totalCharacters = 45;
  for (const report of selected) {
    if (fields.length >= 25) break;
    const name = truncate(`${fields.length + 1}. ${report.player_name}`, 256);
    const value = truncate(storyText(report), 1024);
    if (totalCharacters + name.length + value.length > 6000) continue;
    fields.push({ name, value, inline: false });
    totalCharacters += name.length + value.length;
  }
  const range = windowStartedAt && windowEndedAt ? ` (${windowStartedAt} to ${windowEndedAt})` : '';
  return {
    allowed_mentions: { parse: [] },
    embeds: [{
      title: truncate(`Football transfer digest${range}`, 256),
      color: 0x1d9bf0,
      fields,
      footer: { text: `${fields.length} new material report${fields.length === 1 ? '' : 's'}` },
    }],
  };
}

export function recoverInterruptedDelivery(delivery) {
  if (delivery?.status === 'sending') return { ...delivery, status: 'unknown', retryable: false };
  return { ...delivery, retryable: delivery?.status === 'pending' || delivery?.status === 'failed' };
}

export const REPORT_FIELD_NAMES = REPORT_FIELDS;
