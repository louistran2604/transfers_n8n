# Task 7 report

Status: complete.

## Changed files

- `database/migrate.sql`
- `database/migrations/007_probability_active_digest.sql`
- `database/tests/012_probability_active_digest.sql`
- `tests/e2e/scenario.mjs`
- `tests/migrations/run.sh`
- `tests/unit/workflow-lib.test.mjs`
- `workflow/build-workflows.mjs`
- `workflow/football-transfer-monitor.json` (regenerated)
- `workflow/lib.mjs`

## RED evidence

- `node tests/unit/workflow-lib.test.mjs` failed `digest renders active probability details and labels legacy confidence honestly`: expected `Probability: 62% (▲ +11)`, received `Confidence: 70%`.
- `sh tests/migrations/run.sh` reached the new SQL test after migrations/tests 001-011, then failed at `database/tests/012_probability_active_digest.sql:13` with `active probability function is missing` because `apply_probability_v1_active(bigint,jsonb)` did not exist.

## GREEN verification

- `node --check workflow/lib.mjs && node --check workflow/build-workflows.mjs && node --check tests/e2e/scenario.mjs` — passed.
- `node --test tests/unit/workflow-lib.test.mjs tests/unit/probability-backfill-workflow.test.mjs` — 83 tests passed, 0 failed.
- `node workflow/build-workflows.mjs --check` — checked 78 sources and 3 synchronized workflow files.
- `sh tests/migrations/run.sh` — migration 007 and SQL test 012 passed; existing probability backfill repeatability/concurrency and probability-v1 concurrency passed; runner then reproduced only the unchanged generated-enrichment `old_unresolved_` `\gset` failure at generated SQL line 524.
- `docker compose -f deploy/n8n/compose.yaml config --quiet --no-interpolate` — passed.
- `sh tests/e2e/run.sh` — all three workflows imported; `Mock E2E scenarios passed.` including active Discord rendering and interrupted-send recovery.
- `git diff --check` — passed before commit.

## Commits

- `748ce63` — Enable active probability digests.

## Concerns

- The pre-existing generated-enrichment `old_unresolved_` `\gset` baseline failure remains unchanged after all Task 7 migration, probability, concurrency, and E2E checks pass.
- No deployment, push, merge, rebase, Task 8 fee/value work, scoring-weight change, or external service mutation was performed.
