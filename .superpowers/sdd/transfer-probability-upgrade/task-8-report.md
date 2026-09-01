# Task 8 report

Status: complete and committed after parent review and verification.

## Files changed

- `database/migrate.sql`
- `database/migrations/008_fee_context.sql`
- `database/tests/013_fee_context.sql`
- `database/tests/017_fee_context_concurrency_setup.sql`
- `database/tests/018_fee_context_concurrency_cleanup.sql`
- `tests/e2e/scenario.mjs`
- `tests/migrations/run.sh`
- `tests/migrations/fee-context-concurrency.sh`
- `tests/unit/workflow-lib.test.mjs`
- `workflow/build-workflows.mjs`
- `workflow/football-transfer-monitor.json` (regenerated)
- `workflow/lib.mjs`
- `.superpowers/sdd/transfer-probability-upgrade/task-8-report.md`

The error and probability-backfill workflow JSON files are unchanged.

## RED evidence

- `node tests/unit/workflow-lib.test.mjs` failed `digest renders fresh same-currency fee context compactly and fails open otherwise`: expected `Fee: €25m + €5m add-ons · Sofascore value €20m (1.25x guaranteed, 1.5x incl. add-ons, fresh)`, but received the unchanged `Fee: 25,000,000 EUR` and `Add-ons: 5,000,000 EUR` lines.
- PostgreSQL 16 with migrations 001–007 reached `database/tests/013_fee_context.sql`, then failed at the first projection call with `ERROR: function project_transfer_fee_context(unknown) does not exist`.

## GREEN verification

- `node --test tests/unit/workflow-lib.test.mjs tests/unit/probability-backfill-workflow.test.mjs` — 86 subtests passed, 0 failed across both files. Coverage includes library/generated rendering parity, stale and currency-mismatch omission, fee-only delivered suppression, frozen pending payload reuse, Discord limits, and unchanged probability workflow behavior.
- `node workflow/build-workflows.mjs --check` — checked 78 sources and 3 synchronized workflow files.
- Focused PostgreSQL 16 run of migrations 001–008 plus `database/tests/013_fee_context.sql` — `fee context tests passed`. It covers fresh same-currency base/add-on ratios, exact profile snapshot/as-of/stale audit fields, mismatch, stale, zero value, missing fee, missing enrichment, idempotent replay, delivered suppression, frozen pending payload safety, historical-window suppression, and unchanged probability revision/value/fingerprint/snapshot data.
- `sh tests/migrations/run.sh` — migration 008 applied idempotently; numbered tests through SQL 013 passed; probability backfill repeatability/concurrency, probability-v1 concurrency, and stale concurrency passed. The runner then reproduced only the known generated-enrichment baseline failure at `/tmp/generated-enrichment-persistence.sql:524`: `more than one row returned for \gset`.
- `sh tests/e2e/run.sh` — all 3 workflows imported; `Mock E2E scenarios passed.` The active digest visibly contains the compact fee/value line and interrupted-send recovery remains green.
- `node --check workflow/lib.mjs`; `node --check workflow/build-workflows.mjs`; `node --check tests/e2e/scenario.mjs`; `sh -n tests/migrations/run.sh` — passed.
- `docker compose -f deploy/n8n/compose.yaml config --quiet --no-interpolate` — passed.
- `git diff --quiet -- workflow/football-transfer-monitor-errors.json workflow/football-transfer-probability-backfill.json` — passed; auxiliary workflows are unchanged.
- `git diff --check` — passed.

## Self-review

- Scope: one additive migration/function, existing `current_player_enrichment`, existing immutable revision/content-hash pattern, existing compact-value helpers, and only the generated main workflow were changed.
- Idempotency/concurrency: profile-enriched report rows are locked in a separate ordered statement, then latest revision/delivery/window state is re-read from a fresh READ COMMITTED snapshot before revision numbering; identical context is skipped and content uniqueness remains enforced.
- Frozen delivery safety: any latest revision already referenced by a digest item is excluded, covering both sent and pending deliveries; stored `request_payload` is never rebuilt or updated.
- Notification safety: `fee_context` remains excluded from digest materiality, delivered reports cannot receive a fee-only revision, and projection is limited to the current candidate window so historical undelivered reports are not resurrected.
- Currency/freshness: no conversion; ratios require a positive market value and exact ISO currency matches; add-on ratio additionally requires matching add-on currency; stale contexts retain audit fields but omit ratios and never render a comparison.
- Probability invariance: fee context is appended only to the material snapshot; `probability-v1` functions, tables, fingerprints, normalized values, stages, explanations, thresholds, and Qwen contracts are unchanged.
- Discord safety: the comparison reuses compact amount formatting, retains separate fee/add-on lines when unusable, and existing 25-field/1024-character/6000-character checks remain green.

## Known baseline failure / concerns

- The unrelated generated-enrichment `old_unresolved_` multi-row `\gset` failure at generated SQL line 524 is unchanged and was not edited.
- Stored ratios retain PostgreSQL numeric precision; Discord deterministically displays at most two decimal places.
- No dependency, deployment, production mutation, push, merge, rebase, commit, or Stage 9 work was performed.
- This report is force-added despite `.superpowers/sdd/.gitignore` so the reviewed Stage 8 evidence remains in branch history.

## Fix Round 1: concurrent projection stale snapshot

Status: complete; scoped re-review passed.

### Files changed in this round

- `database/migrations/008_fee_context.sql`
- `database/tests/013_fee_context.sql`
- `database/tests/017_fee_context_concurrency_setup.sql`
- `database/tests/018_fee_context_concurrency_cleanup.sql`
- `tests/migrations/fee-context-concurrency.sh`
- `tests/migrations/run.sh`
- `tests/unit/workflow-lib.test.mjs`
- `.superpowers/sdd/transfer-probability-upgrade/task-8-report.md`

### RED evidence

- Deterministic PostgreSQL 16 command: migrations 001–008 followed by `sh tests/migrations/fee-context-concurrency.sh <container>` against the pre-fix function. A controller locked three reports, two projection sessions blocked with their original statement snapshots, then the controller appended revision 2 and reserved a pending revision before releasing them. Both projection sessions failed with `ERROR: duplicate key value violates unique constraint "transfer_report_revisions_transfer_report_id_revision_numbe_key"`, `Key (transfer_report_id, revision_number)=(2, 2) already exists`, inside `project_transfer_fee_context(...)`. This proves the one-statement lock/read reused stale latest-revision and revision-number state after waiting.

### Fix

- `project_transfer_fee_context` now performs one ordered `FOR UPDATE OF report` lock statement for profile-enriched reports, then runs the projection query as a second SQL statement. Under READ COMMITTED the second statement receives a fresh snapshot and rechecks newest revision, digest reservation, window eligibility, enrichment snapshot, and revision number before inserting.
- No schema, probability, Qwen, delivery, or rendering behavior was otherwise changed.

### GREEN verification

- `sh tests/migrations/fee-context-concurrency.sh <container>` — `fee-context concurrency test passed`. Two concurrent projections produce exactly one fee composite; a concurrently appended material revision remains revision 2 and receives fee context in revision 3; a concurrently reserved pending revision remains the only material revision and its `{"frozen": "exact"}` request payload/digest item are unchanged; cleanup passes.
- Focused PostgreSQL 16 migrations 001–008 plus `database/tests/013_fee_context.sql` — `fee context tests passed`, including new exact-boundary assertions: `profile_fresh_until = requested_at` is stale with no ratios, and base EUR/add-on GBP retains only the valid guaranteed ratio.
- `node --test tests/unit/workflow-lib.test.mjs tests/unit/probability-backfill-workflow.test.mjs` — 86 subtests passed, 0 failed. The partial add-on mismatch renders the base fee/value comparison, preserves the separate GBP add-ons line, and omits `incl. add-ons`.
- Generated mode gate assertion verifies the candidate SQL calls projection only in exact `active` mode and returns `0` in `shadow`/`off`; the active path remains behaviorally exercised by the mock E2E. Executing all three parameterized PostgreSQL-node branches inside the unit runner would duplicate n8n/Postgres scaffolding, so the exact SQL CASE assertion plus active E2E is the smallest meaningful coverage for parent adjudication.
- `sh tests/migrations/run.sh` — SQL 013, the new fee-context concurrency harness, all prior repeatability/concurrency suites passed; runner then reproduced only `/tmp/generated-enrichment-persistence.sql:524: error: more than one row returned for \gset`.
- `node workflow/build-workflows.mjs --check` — checked 78 sources and 3 workflow files.
- `sh tests/e2e/run.sh` — all 3 workflows imported and `Mock E2E scenarios passed.`
- JS/shell syntax checks, Compose config, `git diff --check`, and auxiliary workflow isolation passed.

### Concerns

- Projection deliberately serializes the profile-enriched report set in report-ID order. This favors correctness and the existing row-lock convention; if the enriched report population makes lock duration measurable, a writer-coordinated bounded claim scheme would be the next upgrade.
- The unrelated generated-enrichment line-524 `\gset` baseline failure remains unchanged.

## Final git status

```text
## feature/transfer-probability-upgrade
```

## Parent review and verification

- Independent task review found one Important stale-snapshot concurrency defect and one Minor boundary/mode coverage gap.
- Fix Round 1 addressed both; scoped re-review returned `PASS` with no new findings.
- Fresh parent verification passed 82 workflow-library tests, 4 probability-backfill workflow tests, generator synchronization for 78 sources/3 workflows, JavaScript and shell syntax, Compose configuration, auxiliary-workflow isolation, staged diff checks, and full Docker mock E2E.
- The PostgreSQL runner passed migration 008, SQL 013, fee-context concurrency, and all prior repeatability/concurrency suites before reproducing only the unchanged generated-enrichment line-524 `\\gset` baseline failure.
- Implementation commit: `2502786dfcd240e68137a84e07167d2b71418d1e`.
