import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const workflow = JSON.parse(await readFile(
  new URL('../../workflow/football-transfer-probability-backfill.json', import.meta.url),
  'utf8',
));

const generatedCode = (name) => workflow.nodes.find((node) => node.name === name)?.parameters.jsCode;
const runCode = (name, items, requests, executionId = 'execution-42') => Function(
  '$input', '$', '$execution',
  generatedCode(name),
)({ all: () => items }, () => ({ all: () => requests }), { id: executionId });

const request = {
  json: {
    raw_post_id: '501',
    external_post_id: '900000000000000501',
    post_url: 'https://x.com/test/status/900000000000000501',
    posted_at: '2026-08-20T12:00:00.000Z',
    evaluation_time: '2026-08-27T12:00:00.000Z',
    source: {
      external_account_id: '900000000000000001', username: 'testsource',
      display_name: 'Test Source', priority_rank: 2, reliability_score: 0.85,
      seed_reliability: 0.85, publisher_group_key: 'reporter:test-source',
      source_kind: 'journalist', is_aggregator: false, is_official: false,
    },
  },
};

const report = {
  player_name: 'Test Player', player_identity_hint: null,
  current_club_name: 'Old FC', former_club_name: null, destination_club_name: 'New FC',
  move_effective_on: null,
  classification: 'rumor', move_type: 'permanent', fee_amount: null, fee_currency: null,
  add_ons_amount: null, add_ons_currency: null, release_clause_amount: null,
  release_clause_currency: null, contract_length_months: null, contract_expires_on: null,
  loan_ends_on: null, has_option_to_buy: null, has_obligation_to_buy: null,
  sell_on_percentage: null, medical_status: 'not_reported', agreement_status: 'not_reported',
  is_huge_rumor: false, is_digest_worthy: false, stage_signal: 'advanced',
  claim_stance: 'supports', wording_strength: 'direct', club_agreement_state: 'talks',
  personal_terms_state: 'talks', completion_claim: 'none', attribution_kind: 'original',
  named_originator: null, extraction_confidence: 0.9,
};

const responseItem = (value) => ({ json: { body: { choices: [{ message: { content: JSON.stringify(value) } }] } } });

test('generated probability backfill code nodes contain valid JavaScript', () => {
  for (const node of workflow.nodes.filter((node) => node.type === 'n8n-nodes-base.code')) {
    assert.doesNotThrow(() => Function(node.parameters.jsCode), node.name);
  }
});

test('generated backfill mappings produce completion and failure parameters', () => {
  const transferValidated = runCode(
    'Validate backfill Qwen response',
    [responseItem({ transfer_related: true, reports: [report] })],
    [request],
  );
  const transfer = runCode('Build shadow report payloads', transferValidated, [request])[0].json.params;
  assert.deepEqual(transfer.slice(0, 4), ['501', 'qwen-evidence-v1', 'execution-42', request.json.evaluation_time]);
  const transferPayload = JSON.parse(transfer[4]);
  assert.equal(transferPayload.length, 1);
  assert.equal(transferPayload[0].sources[0].raw_post_id, '501');
  assert.equal(transferPayload[0].sources[0].source.username, 'testsource');
  assert.equal(transferPayload[0].probability_mode, 'shadow');

  const ignoredValidated = runCode(
    'Validate backfill Qwen response',
    [responseItem({ transfer_related: false, reports: [] })],
    [request],
  );
  const ignored = runCode('Build shadow report payloads', ignoredValidated, [request])[0].json.params;
  assert.deepEqual(JSON.parse(ignored[4]), []);
  const emptyTransferValidated = runCode(
    'Validate backfill Qwen response',
    [responseItem({ transfer_related: true, reports: [] })],
    [request],
  );
  const emptyTransfer = runCode('Build shadow report payloads', emptyTransferValidated, [request])[0].json.params;
  assert.deepEqual(JSON.parse(emptyTransfer[4]), []);

  const invalidValidated = runCode(
    'Validate backfill Qwen response',
    [responseItem({ transfer_related: true, reports: [{ player_name: 'Incomplete' }] })],
    [request],
  );
  const failed = runCode('Prepare failed replay release', invalidValidated, [request])[0].json.params;
  assert.deepEqual(failed, [
    '501', 'qwen-evidence-v1', 'execution-42', 'Malformed or schema-invalid Qwen response',
  ]);
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
