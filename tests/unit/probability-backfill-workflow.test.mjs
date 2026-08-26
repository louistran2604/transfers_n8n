import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const workflow = JSON.parse(await readFile(
  new URL('../../workflow/football-transfer-probability-backfill.json', import.meta.url),
  'utf8',
));

test('generated probability backfill code nodes contain valid JavaScript', () => {
  for (const node of workflow.nodes.filter((node) => node.type === 'n8n-nodes-base.code')) {
    assert.doesNotThrow(() => Function(node.parameters.jsCode), node.name);
  }
});

test('probability backfill is manual-only, shadow-only, and isolated from delivery paths', () => {
  assert.deepEqual(
    workflow.nodes.filter((node) => node.type.endsWith('Trigger')).map((node) => node.type),
    ['n8n-nodes-base.manualTrigger'],
  );
  const names = workflow.nodes.map((node) => node.name).join('\n');
  assert.doesNotMatch(names, /discord|digest|collector|sofascore|delivery/i);
  const generated = JSON.stringify(workflow);
  assert.doesNotMatch(generated, /transfer_report_revisions|digest_items|digest_deliveries|processing_state|classified_at/i);
  const context = workflow.nodes.find((node) => node.name === 'Prepare shadow backfill');
  assert.match(context.parameters.jsCode, /selected !== 'shadow'/);
  assert.match(context.parameters.jsCode, /return \[\]/);
});

test('probability backfill claims a fixed oldest-first batch and emits deterministic audit data', () => {
  const claim = workflow.nodes.find((node) => node.name === 'Claim replay batch');
  assert.match(claim.parameters.query, /claim_probability_backfill/);
  assert.match(claim.parameters.query, /100/);
  const request = workflow.nodes.find((node) => node.name === 'Build backfill Qwen request');
  assert.match(request.parameters.jsCode, /evaluation_time/);
  const payloads = workflow.nodes.find((node) => node.name === 'Build shadow report payloads');
  assert.match(payloads.parameters.jsCode, /qwen-evidence-v1/);
  const audit = workflow.nodes.find((node) => node.name === 'Build deterministic audit');
  assert.match(audit.parameters.query, /probability_backfill_audit/);
});
