#!/usr/bin/env node
import { readFile, writeFile } from 'node:fs/promises';

const output = process.argv[2];
if (!output) throw new Error('Usage: generated-enrichment-persistence.mjs OUTPUT.sql');

const workflow = JSON.parse(await readFile(new URL('../../workflow/football-transfer-monitor.json', import.meta.url), 'utf8'));
const node = workflow.nodes.find((candidate) => candidate.name === 'Persist soccerdata enrichment result');
if (!node?.parameters?.query) throw new Error('Generated persistence query not found');
const contextNode = workflow.nodes.find((candidate) => candidate.name === 'Load player enrichment contexts');
if (!contextNode?.parameters?.query) throw new Error('Generated context query not found');

const hash = (character) => character.repeat(64);
const identity = (id, name) => ({
  provider: 'sofascore', provider_player_id: id,
  stable_source_identifier: `sofascore:player:${id}`,
  canonical_name: name, score: 80, margin: 80, resolver_version: 'identity-v6',
});
const profile = (id, name, teamId, teamName) => ({
  canonical_name: name,
  current_club: { provider_team_id: teamId, name: teamName },
  retrieved_at: '2026-08-09T00:00:00Z', content_sha256: hash('a'), raw_sha256: hash('b'),
  raw_cache_key: `profile-${id}`, raw_payload: { player: { team: { country: { name: 'Testland' }, category: { name: 'Test' } } } },
});
const statistics = (id, competitionId, seasonId) => ({
  provider_unique_tournament_id: competitionId, competition: `League ${competitionId}`,
  provider_season_id: seasonId, season: '2026', season_state: 'active',
  scope: 'selected_domestic_league_all_clubs', retrieved_at: '2026-08-09T00:00:00Z',
  content_sha256: hash('c'), raw_sha256: hash('d'),
  raw_cache_key: `statistics-${id}-${competitionId}-${seasonId}`, raw_payload: {},
});
const item = ({ key, reportId, playerId, name, teamId, teamName, competitionId, seasonId }) => ({
  item_key: key, report_ids: [String(reportId)], status: 'fresh', resolver_version: 'identity-v6',
  retryable: false, provider_calls: 2, cache_hits: 0,
  request_context: { reported_name_key: name.toLowerCase() },
  identity: identity(playerId, name), profile: profile(playerId, name, teamId, teamName),
  statistics: statistics(playerId, competitionId, seasonId), candidates: [], warning_codes: [], error: null,
});
const payload = (requestId, items) => JSON.stringify({ request_id: requestId, items });
const literal = (value) => `$payload$${value}$payload$::jsonb`;

const aliasPayload = payload('generated-alias', [
  {
    item_key: 'bruno-a', report_ids: ['900575'], status: 'partial', resolver_version: 'identity-v6',
    retryable: false, provider_calls: 1, cache_hits: 0,
    request_context: { reported_name_key: 'bruno guimarães' }, identity: identity('866469', 'Bruno Guimarães'),
    profile: profile('866469', 'Bruno Guimarães', '9702', 'Alias Team'), statistics: null, candidates: [], warning_codes: [], error: null,
  },
  {
    item_key: 'bruno-b', report_ids: ['900585'], status: 'partial', resolver_version: 'identity-v6',
    retryable: false, provider_calls: 1, cache_hits: 0,
    request_context: { reported_name_key: 'bruno guimarães' }, identity: identity('866469', 'Bruno Guimarães'),
    profile: profile('866469', 'Bruno Guimarães', '9702', 'Alias Team'), statistics: null, candidates: [], warning_codes: [], error: null,
  },
]);
const duplicateMappingPayload = payload('generated-duplicate-mapping', [
  item({ key: 'duplicate-a', reportId: 900601, playerId: '9601', name: 'Duplicate A', teamId: '9700', teamName: 'Same Team', competitionId: '9800', seasonId: '9900' }),
  item({ key: 'duplicate-b', reportId: 900602, playerId: '9602', name: 'Duplicate B', teamId: '9700', teamName: 'Same Team', competitionId: '9800', seasonId: '9900' }),
]);
const contradictoryMappingPayload = payload('generated-contradictory-mapping', [
  item({ key: 'conflict-a', reportId: 900603, playerId: '9603', name: 'Conflict A', teamId: '9701', teamName: 'Conflict Team', competitionId: '9801', seasonId: '9901' }),
  item({ key: 'conflict-b', reportId: 900604, playerId: '9604', name: 'Conflict B', teamId: '9701', teamName: 'Conflict Team', competitionId: '9802', seasonId: '9902' }),
]);

const sql = `\\set ON_ERROR_STOP on
INSERT INTO workflow_runs (id, workflow_name, external_execution_id, logical_run_key, status)
OVERRIDING SYSTEM VALUE VALUES (900077, 'fixture', 'generated-persistence', 'generated-persistence', 'running');
INSERT INTO transfer_reports (
  id, dedupe_key, reported_player_name, current_club_name, destination_club_name,
  classification, move_type, confidence, first_reported_at, last_reported_at
) OVERRIDING SYSTEM VALUE VALUES
  (900575, 'fixture-575', 'Bruno Guimarães', 'Newcastle', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (900585, 'fixture-585', 'Bruno Guimarães', 'Newcastle', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (900601, 'fixture-601', 'Duplicate A', 'Same Team', 'Other', 'official_confirmed', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (900602, 'fixture-602', 'Duplicate B', 'Same Team', 'Other', 'official_confirmed', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (900603, 'fixture-603', 'Conflict A', 'Conflict Team', 'Other', 'official_confirmed', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (900604, 'fixture-604', 'Conflict B', 'Conflict Team', 'Other', 'official_confirmed', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
INSERT INTO transfer_reports (
  id, dedupe_key, reported_player_name, current_club_name, destination_club_name,
  classification, move_type, confidence, first_reported_at, last_reported_at
) OVERRIDING SYSTEM VALUE VALUES
  (900605, 'fixture-605', 'Old Resolver', 'Barcelona', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP),
  (900606, 'fixture-606', 'Current Resolver', 'Barcelona', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP);
INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot) VALUES
  (900605, 1, '${hash('e')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900606, 1, '${hash('f')}', '{"is_huge_rumor":false,"is_digest_worthy":true}');
INSERT INTO players (identity_key, display_name, normalized_name) VALUES
  ('alias-unique', 'Alias Unique', 'alias unique'),
  ('alias-ambiguous-a', 'Alias Ambiguous A', 'alias ambiguous a'),
  ('alias-ambiguous-b', 'Alias Ambiguous B', 'alias ambiguous b'),
  ('alias-report-specific', 'Alias Report Specific', 'alias report specific');
INSERT INTO player_provider_ids (
  player_id, provider_player_id, canonical_name, mapping_source,
  resolver_version, verified_at, last_seen_at
) SELECT id, provider_id, display_name, 'automatic', 'identity-v6', CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
FROM players JOIN (VALUES
  ('alias-unique', '9101'), ('alias-ambiguous-a', '9102'),
  ('alias-ambiguous-b', '9103'), ('alias-report-specific', '9104')
) fixture(identity_key, provider_id) USING (identity_key);
INSERT INTO player_aliases (player_id, alias, unicode_key, folded_key, alias_type, source, is_active)
SELECT id, alias_key, alias_key, alias_key, 'report', 'fixture', active
FROM players JOIN (VALUES
  ('alias-unique', 'unique alias', true),
  ('alias-ambiguous-a', 'ambiguous alias', true),
  ('alias-ambiguous-b', 'ambiguous alias', true),
  ('alias-unique', 'inactive alias', false),
  ('alias-unique', 'precedence alias', true),
  ('alias-report-specific', 'legacy pláyer jr', true)
) fixture(identity_key, alias_key, active) USING (identity_key);
INSERT INTO transfer_reports (
  id, dedupe_key, reported_player_name, current_club_name, destination_club_name,
  classification, move_type, confidence, first_reported_at, last_reported_at, normalized_data
) OVERRIDING SYSTEM VALUE VALUES
  (900607, 'fixture-607', 'Unique Alias', 'Club', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{"reported_name_key":"unique alias"}'),
  (900608, 'fixture-608', 'Ambiguous Alias', 'Club', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{"reported_name_key":"ambiguous alias"}'),
  (900609, 'fixture-609', 'Inactive Alias', 'Club', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{"reported_name_key":"inactive alias"}'),
  (900610, 'fixture-610', 'Precedence Alias', 'Club', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{"reported_name_key":"precedence alias"}');
INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot) VALUES
  (900607, 1, '${hash('1')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900608, 1, '${hash('2')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900609, 1, '${hash('3')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900610, 1, '${hash('4')}', '{"is_huge_rumor":false,"is_digest_worthy":true}');
INSERT INTO transfer_report_player_resolutions (
  transfer_report_id, player_provider_id, resolution_source, resolver_version, verified_at
) SELECT 900610, provider.id, 'automatic', 'identity-v6', CURRENT_TIMESTAMP
FROM player_provider_ids provider WHERE provider.provider_player_id = '9104';
INSERT INTO transfer_reports (
  id, dedupe_key, reported_player_name, current_club_name, destination_club_name,
  classification, move_type, confidence, first_reported_at, last_reported_at, normalized_data
) OVERRIDING SYSTEM VALUE VALUES
  (900611, 'fixture-611', 'Shared Player', 'Club A', 'Destination', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{"reported_name_key":"shared player","current_club_key":"club a","destination_club_key":"destination"}'),
  (900612, 'fixture-612', 'Shared Player', 'Club B', 'Destination', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{"reported_name_key":"shared player","current_club_key":"club b","destination_club_key":"destination"}'),
  (900613, 'fixture-613', 'Legacy Pláyer, Jr.', 'Légacy-Club F.C.', 'Legacy Destination (City)', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{}'),
  (900614, 'fixture-614', 'Due Transient', 'Club', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{}'),
  (900615, 'fixture-615', 'Future Transient', 'Club', 'Other', 'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP, '{}');
INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot) VALUES
  (900611, 1, '${hash('5')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900612, 1, '${hash('6')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900613, 1, '${hash('7')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900614, 1, '${hash('8')}', '{"is_huge_rumor":false,"is_digest_worthy":true}'),
  (900615, 1, '${hash('9')}', '{"is_huge_rumor":false,"is_digest_worthy":true}');
INSERT INTO player_identity_overrides (
  reported_name_key, current_club_key, destination_club_key, override_action,
  provider_player_id, effective_at, reason, operator_name
) VALUES
  ('shared player', 'club a', 'destination', 'resolve', '9101', CURRENT_TIMESTAMP - interval '1 hour', 'fixture', 'test'),
  ('shared player', 'club b', 'destination', 'resolve', '9102', CURRENT_TIMESTAMP - interval '1 hour', 'fixture', 'test'),
  ('legacy pláyer jr', 'légacy club f c', 'legacy destination city', 'resolve', '9104', CURRENT_TIMESTAMP - interval '1 hour', 'fixture', 'test');
INSERT INTO player_enrichment_attempts (
  request_key, batch_request_key, item_key, workflow_run_id, transfer_report_id,
  status, retryable, next_retry_at, request_context, evidence, started_at, completed_at
) VALUES
  ('fixture-old-version', 'fixture-old-version', 'old-version', 900077, 900605,
   'unresolved', true, CURRENT_TIMESTAMP + interval '24 hours', '{}', '{"resolver_version":"identity-v5"}', CURRENT_TIMESTAMP - interval '1 hour', CURRENT_TIMESTAMP - interval '1 hour'),
  ('fixture-current-version', 'fixture-current-version', 'current-version', 900077, 900606,
   'unresolved', true, CURRENT_TIMESTAMP + interval '24 hours', '{}', '{"resolver_version":"identity-v6"}', CURRENT_TIMESTAMP - interval '1 hour', CURRENT_TIMESTAMP - interval '1 hour'),
  ('fixture-due-transient', 'fixture-due-transient', 'due-transient', 900077, 900614,
   'provider_failure', true, CURRENT_TIMESTAMP - interval '1 minute', '{}', '{"resolver_version":"identity-v5"}', CURRENT_TIMESTAMP - interval '5 minutes', CURRENT_TIMESTAMP - interval '5 minutes'),
  ('fixture-future-transient', 'fixture-future-transient', 'future-transient', 900077, 900615,
   'deferred', true, CURRENT_TIMESTAMP + interval '5 minutes', '{}', '{"resolver_version":"identity-v6"}', CURRENT_TIMESTAMP - interval '5 minutes', CURRENT_TIMESTAMP - interval '5 minutes');

PREPARE generated_context(jsonb, text) AS
${contextNode.parameters.query};
PREPARE generated_context_current(jsonb, text) AS
SELECT *
FROM (${contextNode.parameters.query.replace(/;\s*$/, '')}) context_rows
WHERE context_rows.is_current_request;
EXECUTE generated_context_current('["900614","900614"]'::jsonb, '900077') \\gset context_
\\if :{?context_transfer_report_id}
\\else
  \\quit 1
\\endif
\\if :context_is_current_request
\\else
  \\quit 1
\\endif
\\if :context_force_resolver_retry
\\else
  \\quit 1
\\endif
SELECT CASE WHEN :'context_transfer_report_id' = '900614' THEN true ELSE false END AS due_transient_retry_ok \\gset
\\if :due_transient_retry_ok
\\else
  \\quit 1
\\endif
UPDATE player_enrichment_attempts
SET next_retry_at = CURRENT_TIMESTAMP + interval '5 minutes'
WHERE transfer_report_id = 900614;
UPDATE player_enrichment_attempts
SET evidence = jsonb_set(evidence, '{resolver_version}', '"identity-v6"')
WHERE transfer_report_id = 900614;
EXECUTE generated_context('[]'::jsonb, '900077') \\gset old_unresolved_
\\if :old_unresolved_force_resolver_retry
\\else
  \\quit 1
\\endif
SELECT CASE WHEN :'old_unresolved_transfer_report_id' = '900605'
  AND :'old_unresolved_is_current_request' = 'f' THEN true ELSE false END AS young_v5_unresolved_selected_ok \\gset
\\if :young_v5_unresolved_selected_ok
\\else
  \\quit 1
\\endif
UPDATE player_enrichment_attempts
SET evidence = jsonb_set(evidence, '{resolver_version}', '"identity-v6"')
WHERE transfer_report_id = 900605;
PREPARE generated_context_count(jsonb, text) AS
SELECT count(*) AS historical_count,
  count(*) FILTER (WHERE transfer_report_id = '900606') AS young_v6_unresolved_count,
  count(*) FILTER (WHERE transfer_report_id = '900615') AS future_v6_transient_count
FROM (${contextNode.parameters.query.replace(/;\s*$/, '')}) context_rows;
EXECUTE generated_context_count('[]'::jsonb, '900077') \\gset current_version_
SELECT :current_version_historical_count = 0
  AND :current_version_young_v6_unresolved_count = 0
  AND :current_version_future_v6_transient_count = 0 AS v6_cooldowns_ok \\gset
\\if :v6_cooldowns_ok
\\else
  \\quit 1
\\endif
UPDATE player_enrichment_attempts
SET evidence = jsonb_set(evidence, '{resolver_version}', '"identity-v5"')
WHERE transfer_report_id = 900614;
EXECUTE generated_context('[]'::jsonb, '900077') \\gset future_transient_
\\if :future_transient_force_resolver_retry
\\else
  \\quit 1
\\endif
SELECT CASE WHEN :'future_transient_transfer_report_id' = '900614'
  AND :'future_transient_is_current_request' = 'f' THEN true ELSE false END AS future_v5_transient_selected_ok \\gset
\\if :future_v5_transient_selected_ok
\\else
  \\quit 1
\\endif
UPDATE player_enrichment_attempts
SET evidence = jsonb_set(evidence, '{resolver_version}', '"identity-v6"')
WHERE transfer_report_id = 900614;
EXECUTE generated_context_count('[]'::jsonb, '900077') \\gset future_version_
SELECT :future_version_historical_count = 0
  AND :future_version_young_v6_unresolved_count = 0
  AND :future_version_future_v6_transient_count = 0 AS future_v6_backoff_ok \\gset
\\if :future_v6_backoff_ok
\\else
  \\quit 1
\\endif
EXECUTE generated_context('["900607"]'::jsonb, '900077') \\gset unique_
SELECT :'unique_provider_player_id' = '9101' AS unique_alias_ok \\gset
\\if :unique_alias_ok
\\else
  \\quit 1
\\endif
EXECUTE generated_context('["900608"]'::jsonb, '900077') \\gset ambiguous_
\\if :{?ambiguous_provider_player_id}
  \\quit 1
\\endif
EXECUTE generated_context('["900609"]'::jsonb, '900077') \\gset inactive_
\\if :{?inactive_provider_player_id}
  \\quit 1
\\endif
EXECUTE generated_context('["900610"]'::jsonb, '900077') \\gset precedence_
SELECT :'precedence_provider_player_id' = '9104' AS report_resolution_precedence_ok \\gset
\\if :report_resolution_precedence_ok
\\else
  \\quit 1
\\endif
EXECUTE generated_context('["900611"]'::jsonb, '900077') \\gset club_a_
SELECT (:'club_a_identity_overrides'::jsonb->0->>'provider_player_id') = '9101' AS club_a_override_ok \\gset
\\if :club_a_override_ok
\\else
  \\quit 1
\\endif
EXECUTE generated_context('["900612"]'::jsonb, '900077') \\gset club_b_
SELECT (:'club_b_identity_overrides'::jsonb->0->>'provider_player_id') = '9102' AS club_b_override_ok \\gset
\\if :club_b_override_ok
\\else
  \\quit 1
\\endif
EXECUTE generated_context('["900613"]'::jsonb, '900077') \\gset legacy_
SELECT :'legacy_provider_player_id' = '9104' AS legacy_alias_ok \\gset
\\if :legacy_alias_ok
\\else
  \\quit 1
\\endif
SELECT (:'legacy_identity_overrides'::jsonb->0->>'provider_player_id') = '9104' AS legacy_override_ok \\gset
\\if :legacy_override_ok
\\else
  \\quit 1
\\endif
INSERT INTO transfer_reports (
  id, dedupe_key, reported_player_name, current_club_name, destination_club_name,
  classification, move_type, confidence, first_reported_at, last_reported_at
) OVERRIDING SYSTEM VALUE
SELECT id, 'historical-cap-' || id, 'Historical ' || id, 'Club', 'Other',
  'rumor', 'permanent', 0.9, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
FROM generate_series(900700, 900725) id;
INSERT INTO transfer_report_revisions (transfer_report_id, revision_number, content_sha256, snapshot)
SELECT id, 1, lpad(to_hex(id), 64, '0'), '{"is_huge_rumor":false,"is_digest_worthy":true}'
FROM generate_series(900700, 900725) id;
INSERT INTO player_enrichment_attempts (
  request_key, batch_request_key, item_key, workflow_run_id, transfer_report_id,
  status, retryable, next_retry_at, request_context, evidence, started_at, completed_at
)
SELECT 'historical-cap-' || id, 'historical-cap', 'historical-cap-' || id, 900077, id,
  'provider_failure', true, CURRENT_TIMESTAMP - interval '1 minute', '{}',
  '{"resolver_version":"identity-v4"}', CURRENT_TIMESTAMP - interval '2 hours', CURRENT_TIMESTAMP - interval '2 hours'
FROM generate_series(900700, 900725) id;
EXECUTE generated_context_count('[]'::jsonb, '900077') \\gset cap_
SELECT :cap_historical_count = 25 AS historical_cap_ok \\gset
\\if :historical_cap_ok
\\else
  \\quit 1
\\endif
DEALLOCATE generated_context_count;
DEALLOCATE generated_context_current;
DEALLOCATE generated_context;

PREPARE generated_persist(jsonb, bigint) AS
${node.parameters.query};
EXECUTE generated_persist(${literal(aliasPayload)}, 900077);
DO $check$
BEGIN
  IF (SELECT count(*) FROM player_enrichment_attempts WHERE batch_request_key = 'generated-alias') <> 2 THEN RAISE EXCEPTION 'expected two attempts'; END IF;
  IF (SELECT count(*) FROM player_provider_ids WHERE provider_player_id = '866469') <> 1 THEN RAISE EXCEPTION 'expected one provider ID'; END IF;
  IF (SELECT count(*) FROM player_aliases alias JOIN player_provider_ids provider ON provider.player_id = alias.player_id WHERE provider.provider_player_id = '866469' AND alias.unicode_key = 'bruno guimarães') <> 1 THEN RAISE EXCEPTION 'expected one alias'; END IF;
  IF (SELECT count(*) FROM transfer_report_player_resolutions WHERE transfer_report_id IN (900575, 900585)) <> 2 THEN RAISE EXCEPTION 'expected two report resolutions'; END IF;
  IF (SELECT alias.evidence->>'transfer_report_id' FROM player_aliases alias JOIN player_provider_ids provider ON provider.player_id = alias.player_id WHERE provider.provider_player_id = '866469' AND alias.unicode_key = 'bruno guimarães') <> '900575' THEN RAISE EXCEPTION 'alias did not retain smallest report'; END IF;
  IF (SELECT count(DISTINCT evidence->>'item_key') FROM transfer_report_player_resolutions WHERE transfer_report_id IN (900575, 900585)) <> 2 THEN RAISE EXCEPTION 'per-report resolution evidence lost'; END IF;
  IF (SELECT count(*) FROM player_enrichment_attempts WHERE batch_request_key = 'generated-alias' AND retryable) <> 0 THEN RAISE EXCEPTION 'resolved alias fixture must not retry'; END IF;
  IF (SELECT count(*) FROM player_enrichment_attempts WHERE batch_request_key = 'generated-alias' AND evidence->>'resolver_version' = 'identity-v6') <> 2 THEN RAISE EXCEPTION 'attempt resolver version missing'; END IF;
END
$check$;

EXECUTE generated_persist(${literal(duplicateMappingPayload)}, 900077);
DO $check$
BEGIN
  IF (SELECT count(*) FROM team_competition_mappings mapping JOIN provider_teams team ON team.id = mapping.provider_team_id WHERE team.provider_team_id = '9700' AND mapping.superseded_at IS NULL) <> 1 THEN RAISE EXCEPTION 'duplicate mapping was not deduplicated'; END IF;
END
$check$;

EXECUTE generated_persist(${literal(contradictoryMappingPayload)}, 900077);
DO $check$
BEGIN
  IF (SELECT count(*) FROM team_competition_mappings mapping JOIN provider_teams team ON team.id = mapping.provider_team_id WHERE team.provider_team_id = '9701' AND mapping.superseded_at IS NULL) <> 0 THEN RAISE EXCEPTION 'contradictory mapping was guessed'; END IF;
END
$check$;
DEALLOCATE generated_persist;
`;

await writeFile(output, sql);
