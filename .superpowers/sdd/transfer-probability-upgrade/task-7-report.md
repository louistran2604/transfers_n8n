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

## Fix round 1 (seven Important review findings)

Status: complete.

### Changed files

- `database/migrations/007_probability_active_digest.sql`
- `database/tests/012_probability_active_digest.sql`
- `database/tests/013_probability_stale_concurrency_setup.sql`
- `database/tests/014_probability_stale_concurrency_cleanup.sql`
- `tests/migrations/probability-stale-concurrency.sh`
- `tests/migrations/run.sh`
- `tests/unit/workflow-lib.test.mjs`
- `workflow/build-workflows.mjs`
- `workflow/football-transfer-monitor.json` (regenerated)
- `workflow/lib.mjs`

### RED evidence

- `node tests/unit/workflow-lib.test.mjs` — 77 passed, 3 failed: a positive delta incorrectly rendered `-6 pts from competition`; a competition-only negative delta rendered `contradictory reporting`; and off-mode `Create stale recompute context` returned one downstream item instead of `[]`.
- `tests/migrations/run.sh` — reached SQL 012 and failed at `newest core revision was not followed by an active composite` before the production fix.
- Isolated pre-fix two-session run using `database/tests/013_probability_stale_concurrency_setup.sql`, `database/tests/014_probability_stale_concurrency_cleanup.sql`, and `tests/migrations/probability-stale-concurrency.sh` — `stale concurrency claims=5:5:1`, then exit 1; both sweeps processed the same five cases in one backend-visible claim set rather than ten unique cases across two backends.

### GREEN verification

- `node --test tests/unit/workflow-lib.test.mjs tests/unit/probability-backfill-workflow.test.mjs` — 2 test files passed, 0 failed; direct focused run reports all 80 workflow-lib subtests passing.
- `node --check workflow/lib.mjs && node --check workflow/build-workflows.mjs && node --check tests/e2e/scenario.mjs && sh -n tests/migrations/probability-stale-concurrency.sh` — passed.
- `node workflow/build-workflows.mjs --check` — checked 78 sources and 3 synchronized workflow files.
- `tests/migrations/run.sh` — SQL 012 passed; probability backfill repeatability/concurrency and probability-v1 concurrency passed; the true two-session stale concurrency harness passed twice with 10 unique cases, 2 backends, no overlap, and full cleanup. The runner then reached only the unchanged generated-enrichment SQL line 524 `\gset` baseline failure.
- `docker compose -f deploy/n8n/compose.yaml config --quiet --no-interpolate` — passed.
- `sh tests/e2e/run.sh` — exit 0; all workflows imported and `Mock E2E scenarios passed`, including interrupted-delivery recovery.
- `git diff --check` and the final cached diff check — passed.

### Commits

- `d405216` — Fix active probability digest edge cases.

### Concerns

- The known generated-enrichment `old_unresolved_`/line-524 `\gset` baseline failure remains after every Task 7 probability and concurrency check passes.
- No deployment, push, merge, rebase, Task 8 fee/value work, scoring-weight change, Qwen evidence change, or dependency addition was performed.
