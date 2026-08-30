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
