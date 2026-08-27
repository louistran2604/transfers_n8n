# Final probability remediation report

## Changes by residual finding

1. **Current-evidence reopening**
   - Added migration 011 and replaced the public `score_transfer_probability_v1(bigint, timestamptz)` definition without adding another scorer/helper.
   - `later_advanced` now requires `active_rank = 1`, so same-independence-key advanced evidence superseded by a denial or lower-stage support cannot reopen a collapse.
   - Added apply-path regressions for denial supersession, lower-stage supersession, and an unsuperseded later advanced reopening.

2. **Authoritative reliability and fingerprint inputs**
   - The fallback branches now select the newest `probability-v1` posterior with `calculated_at <= requested_evaluated_at`, falling back to the established clamped seed/current compatibility value only when no eligible snapshot exists.
   - Reopen and contradiction branches use one canonical deterministic fingerprint input containing engine version, requested evaluation time, active evidence, effective reliability, and score-affecting recency factors.
   - Added executable checks for later-time decay revisions, newly eligible posterior revisions and score use, and exact same-time replay idempotency.

3. **Shared-reporter settlement locking**
   - The function snapshots the cases eligible at call entry, claims them in bounded chunks, and locks their complete pending source-account union once in ascending global source ID order before any outcome update. Later chunks therefore cannot acquire a lower source lock.
   - The fixture uses two shared reporters in crossed first/second chunks. The harness requires both sessions to succeed and asserts `8:8:2:4:4:8:0` (audit rows, distinct cases, distinct backends, minimum/maximum cases per backend, failures, pending rows) twice.

4. **Round-1 attribution repair**
   - Migration 011 now reproduces migration 004's named-originator lookup, `_resolved_source` seed/compatibility reliability, attribution-gated posting fallback, unresolved aggregation source-kind, and `unknown` independence behavior while retaining as-of posterior selection.
   - Real apply-path tests prove cited reopen evidence uses the named originator's `0.62` compatibility reliability and unresolved aggregated contradiction evidence posted by an official account remains non-official, `unknown`, and at the `0.70` fallback.

## RED evidence

- Reopen current-evidence RED:
  - Command: `docker exec transfers-task9-round1 psql -U transfers -d transfers -v ON_ERROR_STOP=1 -f /database/tests/030_probability_final_remediation.sql`
  - Migration-010 failure: `ERROR: superseded advanced evidence reopened after denial`.
- Reliability/fingerprint RED:
  - Command: `sed -e "/SELECT pg_temp.assert_true('superseded/,/));/d" -e "/SELECT pg_temp.assert_true('current advanced/,/));/d" database/tests/030_probability_final_remediation.sql | docker exec -i transfers-task9-round1 psql -U transfers -d transfers -v ON_ERROR_STOP=1`
  - Migration-010 failure: `ERROR: eligible posterior did not change contradiction scoring`.
- Shared-reporter concurrency RED:
  - Command: `tests/migrations/probability-settlement-concurrency.sh transfers-task9-round1`
  - Migration-010 failure: PostgreSQL `deadlock detected` between the two settlement sessions after they acquired the shared reporters in opposing case order.
- Round-1 attribution RED:
  - Command: `docker exec transfers-task9-round1 psql -U transfers -d transfers -v ON_ERROR_STOP=1 -f /database/tests/030_probability_final_remediation.sql`
  - Accepted migration-011 failure: `ERROR: cited reopen inherited posting-account reliability`.
- Round-1 cross-chunk concurrency RED:
  - Command: `tests/migrations/probability-settlement-concurrency.sh transfers-task9-round1`
  - Accepted migration-011 failure: PostgreSQL `deadlock detected` while each backend entered its reserved second chunk with the other backend's reporter lock.

## GREEN evidence

- Focused SQL:
  - `docker exec transfers-task9-round1 psql -U transfers -d transfers -v ON_ERROR_STOP=1 -f /database/tests/030_probability_final_remediation.sql` → `probability final remediation tests passed`.
- Shared-reporter concurrency:
  - `tests/migrations/probability-settlement-concurrency.sh transfers-task9-round1` → `probability settlement concurrency test passed twice`.
  - Both worker commands exited successfully; each round asserted exactly `8:8:2:4:4:8:0`, proving two participating backends, exactly four cases/two bounded chunks per backend, eight distinct cases and outcomes settled once, and zero pending outcomes.
- Affected SQL:
  - Executed `006`, `007`, `019`, `020`, `021`, `024`, `028`, `029`, and `030` sequentially with `ON_ERROR_STOP=1` → all exited 0; named suite results included engine, normalization, final review, and final remediation passes.
- Node/workflow:
  - `node --test tests/unit/workflow-lib.test.mjs tests/unit/probability-backfill-workflow.test.mjs` → 2 passed, 0 failed.
  - `node workflow/build-workflows.mjs --check` → checked 78 sources and 3 workflow files.

## Migration safety

- Exact 001–010 upgrade:
  - Applied migrations 001 through 010 into isolated database `remediation_upgrade_118431`, then ran `/database/migrate.sql` → `11:011_probability_final_remediation`; temporary database removed after the proof.
  - Repeated after round-1 fixes in isolated database `remediation_upgrade_118432`, including a second idempotent migrate call → `11:011_probability_final_remediation`; temporary database removed.
- Fresh, repeat, and concurrent fresh:
  - `tests/migrations/run.sh` applied the current migration set to the main test database, repeated `/database/migrate.sql`, and ran two concurrent fresh migrations; the hard count assertion passed at 11.
  - All subsequent probability, normalization, reliability, settlement, backfill, stale, same-time, fee, and generated probability candidate stages passed.
- Full-run known baseline:
  - `tests/migrations/run.sh` → pre-existing generated-enrichment `old_unresolved_` multi-row `\gset` failure at generated SQL line 524; unchanged/deferred exactly as permitted by the brief.
  - Round-1 rerun reached the same exact stopping point after the strengthened attribution and two-chunk concurrency tests passed.

## Self-review and remaining concerns

- Public signatures remain `score_transfer_probability_v1(bigint, timestamptz)` and `settle_expired_probability_v1_cases(text, timestamptz, integer)`.
- Migration 010 remains unchanged; migration 011 is additive and ledger-gated.
- The independent review report was preserved unchanged.
- No third scorer/helper, dependency, service, workflow behavior, Discord behavior, TransferTracker ingestion, `.omx` content, or unrelated cleanup was added.
- Final checks: `sh -n` on modified shell files, `git diff --check`, scope/status review, and clean-worktree verification after commit.
- Remaining concern: only the documented unrelated generated-enrichment baseline above.

## Local commit

- Exact SHA: the Git object ID of the single commit containing this report, returned in the completion status and by `git rev-parse HEAD` (the object ID is assigned after this report becomes commit content).
