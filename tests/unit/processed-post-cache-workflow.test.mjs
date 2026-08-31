import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
const AsyncFunction = Object.getPrototypeOf(async () => {}).constructor;
const nodeByName = (name) => {
  const found = workflow.nodes.find((node) => node.name === name);
  assert.ok(found, `missing generated node: ${name}`);
  return found;
};
const target = (name, output = 0) => workflow.connections[name]?.main?.[output]?.[0]?.node;
const post = (externalPostId, content = `post ${externalPostId}`) => ({
  params: ['900000000000000001', externalPostId, `https://x.com/source/status/${externalPostId}`, content, '2026-08-30T00:00:00.000Z', '{}', 'source', 'Source', 1, 0.9, false],
});
const runPrepare = (items, env = {}) => new AsyncFunction('$input', '$env', nodeByName('Prepare processed-post Redis lookup').parameters.jsCode)({ all: () => items.map((json) => ({ json })) }, env);
const runFilter = (items, prepared) => new AsyncFunction('$input', '$', nodeByName('Filter processed-post Redis hits').parameters.jsCode)(
  { all: () => items.map((json) => ({ json })) },
  () => ({ all: () => prepared }),
);
const runSetPrepare = (name, items, env = {}) => new AsyncFunction('$input', '$env', nodeByName(name).parameters.jsCode)({ all: () => items.map((json) => ({ json })) }, env);
const runResume = (durableRows) => new AsyncFunction('$input', '$', nodeByName('Resume merged processing after Redis').parameters.jsCode)(
  { all: () => [{ json: { redis_write: true } }] },
  () => ({ all: () => durableRows.map((json) => ({ json })) }),
);

test('generated twscrape topology checks processed-post Redis before PostgreSQL and keeps samples on a bypass path', () => {
  nodeByName('Prepare processed-post Redis lookup');
  nodeByName('Processed-post Redis cache enabled?');
  nodeByName('Lookup processed-posts via Upstash');
  nodeByName('Filter processed-post Redis hits');
  nodeByName('Bypass processed-post Redis cache');
  assert.equal(workflow.nodes.some((node) => /rapidapi/i.test(node.name)), false);
  assert.doesNotMatch(JSON.stringify(workflow), /RAPIDAPI/i);
  assert.equal(target('Normalize twscrape posts'), 'Prepare processed-post Redis lookup');
  assert.equal(target('Upsert source accounts'), 'Select X collector');
  assert.equal(target('Select X collector'), 'Build twscrape collect request');
  assert.equal(target('Prepare processed-post Redis lookup'), 'Processed-post Redis cache enabled?');
  assert.equal(target('Processed-post Redis cache enabled?', 0), 'Lookup processed-posts via Upstash');
  assert.equal(target('Processed-post Redis cache enabled?', 1), 'Bypass processed-post Redis cache');
  assert.equal(target('Lookup processed-posts via Upstash'), 'Filter processed-post Redis hits');
  assert.equal(target('Filter processed-post Redis hits'), 'Persist raw posts');
  assert.equal(target('Bypass processed-post Redis cache'), 'Persist raw posts');
  assert.equal(target('Load sample collected X posts'), 'Persist raw posts');
  assert.equal(target('Persist raw posts'), 'Build Qwen request');
});

test('terminal PostgreSQL transitions populate Redis only after success and merged processing always resumes', () => {
  for (const name of [
    'Prepare ignored processed-post Redis write',
    'Ignored processed-post Redis cache enabled?',
    'Store ignored processed-post markers via Upstash',
    'Prepare merged processed-post Redis write',
    'Merged processed-post Redis cache enabled?',
    'Store merged processed-post markers via Upstash',
    'Resume merged processing after Redis',
  ]) nodeByName(name);
  assert.equal(target('Mark non-transfer ignored'), 'Prepare ignored processed-post Redis write');
  assert.equal(target('Prepare ignored processed-post Redis write'), 'Ignored processed-post Redis cache enabled?');
  assert.equal(target('Ignored processed-post Redis cache enabled?', 0), 'Store ignored processed-post markers via Upstash');
  assert.equal(target('Prepare merged processed-post Redis write'), 'Merged processed-post Redis cache enabled?');
  assert.equal(target('Merged processed-post Redis cache enabled?', 0), 'Store merged processed-post markers via Upstash');
  assert.equal(target('Merged processed-post Redis cache enabled?', 1), 'Resume merged processing after Redis');
  assert.equal(target('Store merged processed-post markers via Upstash'), 'Resume merged processing after Redis');
  assert.equal(target('Resume merged processing after Redis'), 'Prepare preferred source reset');
  assert.equal(target('Persist merged reports and revisions'), 'Prepare merged processed-post Redis write');
  assert.equal(workflow.connections['Record Qwen validation failure'], undefined);
  assert.equal(nodeByName('Mark non-transfer ignored').continueOnFail, undefined);
  assert.equal(nodeByName('Persist merged reports and revisions').continueOnFail, undefined);
  assert.match(nodeByName('Persist merged reports and revisions').parameters.query, /processed_post_external_ids/);
  assert.match(nodeByName('Validate Qwen response').parameters.jsCode, /external_post_id: request\.external_post_id/);
  assert.match(nodeByName('Merge extracted reports').parameters.jsCode, /processed_post_external_ids/);
});

test('generated Upstash lookup uses a bounded REST pipeline and keeps credentials in environment expressions', () => {
  const lookup = nodeByName('Lookup processed-posts via Upstash');
  assert.match(nodeByName('Prepare processed-post Redis lookup').parameters.jsCode, /UPSTASH_REDIS_REST_URL/);
  assert.equal(lookup.type, 'n8n-nodes-base.httpRequest');
  assert.equal(lookup.parameters.method, 'POST');
  assert.match(lookup.parameters.url, /\$json\.rest_url/);
  assert.match(lookup.parameters.url, /pipeline/);
  assert.match(lookup.parameters.jsonBody, /\$json\.commands/);
  assert.match(JSON.stringify(lookup.parameters.headerParameters), /UPSTASH_REDIS_REST_TOKEN/);
  assert.equal(lookup.continueOnFail, true);
  assert.equal(lookup.parameters.options.response.response.fullResponse, true);
  assert.equal(lookup.parameters.options.response.response.neverError, true);
  assert.ok(Number.isInteger(lookup.parameters.options.timeout) || Number.isInteger(lookup.parameters.options?.timeout));
  assert.doesNotMatch(JSON.stringify(lookup), /read-write-token|example\.upstash/);
});

test('generated Upstash terminal writes use bounded SET pipelines and environment-only credentials', () => {
  for (const name of ['Store ignored processed-post markers via Upstash', 'Store merged processed-post markers via Upstash']) {
    const store = nodeByName(name);
    assert.equal(store.type, 'n8n-nodes-base.httpRequest');
    assert.equal(store.parameters.method, 'POST');
    assert.match(store.parameters.url, /\$json\.rest_url/);
    assert.match(store.parameters.url, /pipeline/);
    assert.match(store.parameters.jsonBody, /\$json\.commands/);
    assert.match(JSON.stringify(store.parameters.headerParameters), /UPSTASH_REDIS_REST_TOKEN/);
    assert.equal(store.continueOnFail, true);
    assert.equal(store.parameters.options.response.response.fullResponse, true);
    assert.equal(store.parameters.options.response.response.neverError, true);
    assert.doesNotMatch(JSON.stringify(store), /read-write-token|example\.upstash/);
  }
});

test('processed-post lookup preparation passes through when off and batches unique IDs when active', async () => {
  const posts = [post('1'), post('2'), post('1')];
  const off = await runPrepare(posts, { UPSTASH_REDIS_MODE: 'off' });
  assert.equal(off.length, posts.length);
  assert.ok(off.every((item) => item.json.redis_lookup === false));
  assert.deepEqual(off.flatMap((item) => item.json.posts), posts);

  const active = await runPrepare(posts, {
    UPSTASH_REDIS_MODE: 'active',
    UPSTASH_REDIS_REST_URL: 'https://example.upstash.io/',
    UPSTASH_REDIS_REST_TOKEN: 'test-token',
    UPSTASH_REDIS_POST_TTL_SECONDS: '3600',
  });
  assert.equal(active.length, 1);
  assert.equal(active[0].json.redis_lookup, true);
  assert.deepEqual(active[0].json.commands, [
    ['GET', 'ftm:v1:processed-post:x:1'],
    ['GET', 'ftm:v1:processed-post:x:2'],
  ]);
  assert.deepEqual(active[0].json.groups.map(({ id, posts: grouped }) => [id, grouped.length]), [['1', 2], ['2', 1]]);

  const invalid = await runPrepare(posts, {
    UPSTASH_REDIS_MODE: 'active',
    UPSTASH_REDIS_REST_URL: 'not-a-url',
    UPSTASH_REDIS_REST_TOKEN: 'test-token',
  });
  assert.equal(invalid.length, posts.length);
  assert.ok(invalid.every((item) => item.json.redis_lookup === false));
});

test('processed-post terminal writes are off by default, deduplicated, terminal-only, and bounded', async () => {
  const activeEnv = {
    UPSTASH_REDIS_MODE: 'active',
    UPSTASH_REDIS_REST_URL: 'https://example.upstash.io',
    UPSTASH_REDIS_REST_TOKEN: 'test-token',
    UPSTASH_REDIS_POST_TTL_SECONDS: '3600',
  };
  const ignored = await runSetPrepare('Prepare ignored processed-post Redis write', [
    { external_post_id: '1' }, { external_post_id: '2' }, { external_post_id: '1' }, { external_post_id: 'not-an-id' },
  ], activeEnv);
  assert.equal(ignored.length, 1);
  assert.equal(ignored[0].json.redis_write, true);
  assert.deepEqual(ignored[0].json.commands, [
    ['SET', 'ftm:v1:processed-post:x:1', 'ignored', 'EX', '3600'],
    ['SET', 'ftm:v1:processed-post:x:2', 'ignored', 'EX', '3600'],
  ]);

  const merged = await runSetPrepare('Prepare merged processed-post Redis write', [
    { processed_post_external_ids: ['1', '2'] },
    { processed_post_external_ids: '["2", "3"]' },
    { processed_post_external_ids: ['not-an-id'] },
  ], activeEnv);
  assert.equal(merged.length, 1);
  assert.equal(merged[0].json.redis_write, true);
  assert.deepEqual(merged[0].json.commands, [
    ['SET', 'ftm:v1:processed-post:x:1', 'merged', 'EX', '3600'],
    ['SET', 'ftm:v1:processed-post:x:2', 'merged', 'EX', '3600'],
    ['SET', 'ftm:v1:processed-post:x:3', 'merged', 'EX', '3600'],
  ]);

  const off = await runSetPrepare('Prepare merged processed-post Redis write', [{ processed_post_external_ids: ['1'] }], { UPSTASH_REDIS_MODE: 'off' });
  assert.equal(off.length, 1);
  assert.equal(off[0].json.redis_write, false);
  assert.deepEqual(off[0].json.commands, []);
});

test('merged Redis write result is ignored so durable merge output resumes preferred-source processing', async () => {
  const durableRows = [{ transfer_report_id: '41', preferred_raw_post_id: '51', processed_post_external_ids: ['61'] }];
  assert.deepEqual(await runResume(durableRows), durableRows.map((json) => ({ json })));
});

test('processed-post Redis hits are filtered while misses and every ambiguous response fail open', async () => {
  const posts = [post('1'), post('2')];
  const prepared = await runPrepare(posts, {
    UPSTASH_REDIS_MODE: 'active',
    UPSTASH_REDIS_REST_URL: 'https://example.upstash.io',
    UPSTASH_REDIS_REST_TOKEN: 'test-token',
  });
  const hitAndMiss = await runFilter([
    { statusCode: 200, body: [{ result: 'ignored' }, { result: null }] },
  ], prepared);
  assert.deepEqual(hitAndMiss.map((item) => item.json), [posts[1]]);

  for (const response of [
    { statusCode: 401, body: 'unauthorized' },
    { statusCode: 429, body: {} },
    { statusCode: 500, body: {} },
    { statusCode: 200, body: '[not json' },
    { statusCode: 200, body: [{ result: null }] },
    { statusCode: 200, body: [{ result: 'pending' }, { result: null }] },
    { statusCode: 200, error: 'request timed out' },
  ]) {
    const failOpen = await runFilter([response], prepared);
    assert.deepEqual(failOpen.map((item) => item.json), posts, JSON.stringify(response));
  }
});

test('manual sample data can be unwrapped without touching Redis', async () => {
  const bypass = nodeByName('Bypass processed-post Redis cache');
  const run = new AsyncFunction('$input', bypass.parameters.jsCode);
  const sample = post('999000000000000001', 'TEST DATA');
  const output = await run({ all: () => [{ json: { redis_lookup: false, posts: [sample] } }] });
  assert.deepEqual(output.map((item) => item.json), [sample]);
});
