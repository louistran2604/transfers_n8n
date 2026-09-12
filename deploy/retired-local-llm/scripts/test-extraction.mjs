import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { readFile } from 'node:fs/promises';
import { canonicalizeReport, loadEntityAliases, validateQwenResponse } from '../../../workflow/lib.mjs';

const baseUrl = process.env.LLAMA_BASE_URL ?? 'http://127.0.0.1:8081';
const model = process.env.MODEL_ALIAS ?? 'qwen3.8-27b';
const fixturePath = new URL('../tests/extraction-fixtures.json', import.meta.url);
const schemaPath = new URL('../../../workflow/qwen-response-schema.json', import.meta.url);
const promptPath = new URL('../../../workflow/qwen-system-prompt.md', import.meta.url);

const fixtures = JSON.parse(await readFile(fixturePath, 'utf8'));
const schema = JSON.parse(await readFile(schemaPath, 'utf8'));
const prompt = await readFile(promptPath, 'utf8');
const entityAliases = await loadEntityAliases(new URL('../../../workflow/entity-aliases.json', import.meta.url));
const requestedFixture = process.env.EXTRACTION_FIXTURE_ID;
const selectedFixtures = requestedFixture
  ? fixtures.filter((fixture) => fixture.id === requestedFixture)
  : fixtures;

assert.ok(selectedFixtures.length > 0, `Unknown extraction fixture: ${requestedFixture}`);

function assertNoReasoning(response, fixtureId) {
  const reasoningKeys = [];
  const visit = (value, path = '$') => {
    if (!value || typeof value !== 'object') return;
    if (Array.isArray(value)) {
      value.forEach((item, index) => visit(item, `${path}[${index}]`));
      return;
    }
    for (const [key, child] of Object.entries(value)) {
      if (/reasoning|thinking/i.test(key)) reasoningKeys.push(`${path}.${key}`);
      visit(child, `${path}.${key}`);
    }
  };
  visit(response);
  assert.deepEqual(reasoningKeys, [], `${fixtureId}: reasoning fields leaked: ${reasoningKeys.join(', ')}`);
  const content = response?.choices?.[0]?.message?.content;
  assert.equal(typeof content, 'string', `${fixtureId}: choices[0].message.content must be a string`);
  assert.doesNotMatch(content, /<\/?think>|<\|(?:thinking|reasoning)[^|]*\|>/i, `${fixtureId}: thinking tags leaked into content`);
}

function assertExpected(fixture, parsed) {
  const { expected } = fixture;
  assert.equal(parsed.transfer_related, expected.transfer_related, `${fixture.id}: transfer_related`);
  assert.equal(parsed.reports.length, expected.report_count, `${fixture.id}: report_count`);
  if (expected.player_names) {
    const names = new Set(parsed.reports.map((report) => report.player_name));
    for (const name of expected.player_names) assert.ok(names.has(name), `${fixture.id}: missing player ${name}`);
  }
  if (!expected.first) return;
  const first = fixture.canonicalize
    ? canonicalizeReport(parsed.reports[0], entityAliases)
    : parsed.reports[0];
  for (const [field, value] of Object.entries(expected.first)) {
    assert.deepEqual(first[field], value, `${fixture.id}: ${field}`);
  }
}

const results = [];
for (const fixture of selectedFixtures) {
  const started = performance.now();
  const response = await fetch(`${baseUrl}/v1/chat/completions`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({
      model,
      temperature: 0,
      max_tokens: 2048,
      messages: [
        { role: 'system', content: prompt },
        { role: 'user', content: fixture.post },
      ],
      response_format: {
        type: 'json_schema',
        json_schema: { name: 'football_transfer_extraction', strict: true, schema },
      },
    }),
    signal: AbortSignal.timeout(180_000),
  });
  const body = await response.json();
  assert.equal(response.ok, true, `${fixture.id}: HTTP ${response.status}: ${JSON.stringify(body)}`);
  assertNoReasoning(body, fixture.id);
  const content = body.choices[0].message.content;
  let parsed;
  try {
    parsed = JSON.parse(content);
  } catch (error) {
    throw new Error(`${fixture.id}: response content is not JSON: ${error.message}\n${content}`);
  }
  const validation = validateQwenResponse(parsed);
  assert.equal(validation.valid, true, `${fixture.id}: schema validation failed: ${validation.errors.join('; ')}`);
  assertExpected(fixture, parsed);
  results.push({ id: fixture.id, milliseconds: Math.round(performance.now() - started) });
}

const total = results.reduce((sum, result) => sum + result.milliseconds, 0);
const first = results[0];
process.stdout.write(`Extraction fixtures passed: ${results.length}; first=${first.milliseconds}ms; average=${Math.round(total / results.length)}ms\n`);
for (const result of results) process.stdout.write(`  ${result.id}: ${result.milliseconds}ms\n`);
