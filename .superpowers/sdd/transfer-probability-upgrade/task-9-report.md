# Task 9 implementation report

## Outcome

Implemented authoritative reporter-claim settlement and immutable `probability-v1`
reliability posterior snapshots in PostgreSQL. The existing probability apply path now
registers eligible claims, settles only official/collapse facts, recomputes affected live
cases under the existing shadow/active boundary, and the daily workflow runs a bounded
lock-safe calendar-window expiry sweep before stale recomputation.

## Commit

- Implementation and tests: `d27f733` (`Add authoritative probability settlement`).

## Files changed

- `database/migrations/009_probability_outcome_settlement.sql`
- `database/migrate.sql`
- `database/tests/019_probability_outcome_settlement.sql`
- `database/tests/020_probability_outcome_boundaries.sql`
- `database/tests/021_probability_reliability_time_travel.sql`
- `database/tests/022_probability_settlement_concurrency_setup.sql`
- `database/tests/023_probability_settlement_concurrency_cleanup.sql`
- `database/tests/010_probability_v1_concurrency_cleanup.sql`
- `database/tests/014_probability_stale_concurrency_cleanup.sql`
- `tests/migrations/probability-settlement-concurrency.sh`
- `tests/migrations/run.sh`
- `tests/unit/workflow-lib.test.mjs`
- `workflow/build-workflows.mjs`
- `workflow/football-transfer-monitor.json`

The error and manual probability-backfill workflows are unchanged.

## TDD evidence

### RED

- Command: `docker exec transfers-task9-red psql -U transfers -d transfers -v ON_ERROR_STOP=1 -f /database/tests/019_probability_outcome_settlement.sql`
- Exit: `3`
- Expected failure: `function probability_v1_register_claims(integer, unknown) does not exist`.

### GREEN

- Clean-schema command applied `database/migrate.sql` twice, then ran
  `005`, `006`, `007`, `012`, and new `019`-`021` PostgreSQL tests.
- Exit: `0`.
- Result: every focused SQL regression printed `PASS`; migration replay was idempotent.
- Command: `tests/migrations/probability-settlement-concurrency.sh transfers-task9-red`
- Exit: `0`.
- Result: two concurrent fixed batches passed twice with six distinct cases and two backends.

## Behavior covered

- First eligible claim, first stage/time preservation, monotonic weight upgrade, repeat
  idempotency, named-originator attribution, official-source and official-announcement exclusion.
- Exact weighted Beta posterior, effective resolved count, `0.55`/`0.95` clamps, and pending exclusion.
- Official destination success plus competing failure, destination-only authoritative collapse,
  non-authoritative collapse ignored, and later completion supersession with old snapshots unchanged.
- H1/H2 UTC grace boundaries, one instant before/exact eligibility, bounded batches, replay,
  and two-session `SKIP LOCKED` processing.
- Snapshot time travel before/at `calculated_at`, unchanged historical fingerprints/revisions,
  and reporter-affected case recomputation in off/shadow/active modes.
- Existing reporter-done 98% cap, official-only 100%, lifecycle, normalization, materiality,
  and frozen delivery behavior remain covered by the existing `006`, `007`, and `012` tests.

## Verification

- `node --test tests/unit/workflow-lib.test.mjs tests/unit/probability-backfill-workflow.test.mjs`
  -> exit `0`, 86 tests passed.
- `node workflow/build-workflows.mjs --check` -> exit `0`, 78 sources and 3 workflows checked.
- `node --check workflow/build-workflows.mjs` -> exit `0`.
- `sh -n tests/migrations/run.sh tests/migrations/probability-settlement-concurrency.sh tests/e2e/run.sh`
  -> exit `0`.
- Production and E2E `docker compose ... config --quiet` with placeholder required variables
  -> exit `0`.
- `sh tests/e2e/run.sh` -> exit `0`, `Mock E2E scenarios passed.`
- `git diff --quiet d7e486cb82031c26351e3271e2611f9f297011be -- workflow/football-transfer-monitor-errors.json workflow/football-transfer-probability-backfill.json`
  -> exit `0`; auxiliary workflows unchanged.
- `git diff --check` -> exit `0`.

## Full migration suite

- Command: `sh tests/migrations/run.sh`
- Exit: `3` only after migration upgrade/replay, every numbered test, and every concurrency
  harness passed.
- Known unchanged baseline failure:
  `generated-enrichment-persistence.sql:524 -> old_unresolved_ query returns multiple rows -> \\gset rejects it`.

## Self-review

- Scope is additive migration/test/workflow wiring only; no dependency, service, registry,
  Qwen scoring/outcome field, backfill path, manual UI, or notification was added.
- Settlement facts require stored official evidence except deterministic clock expiry; window
  settlement stores no fabricated evidence reference.
- Source and case locks are ordered and window selection remains bounded with `SKIP LOCKED`.
- Reliability snapshots and probability/material revisions are append-only; replay produces no
  additional claim, outcome, snapshot, or fingerprint-identical revision.
- During review, fixed shared-source multi-case expiry aggregation so one sweep appends the
  posterior only after all selected outcomes are settled.

## Concerns / blockers

- No Stage 9 blocker.
- The documented generated-enrichment `old_unresolved_` baseline failure remains intentionally unchanged.
