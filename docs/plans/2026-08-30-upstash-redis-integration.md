# Optional Upstash Redis integration

## Scope and invariants

Upstash Redis is an optional, non-authoritative acceleration cache for already-processed X posts. PostgreSQL remains the durable source of truth and keeps its existing deduplication, retry, merge, enrichment, probability, digest, and Discord behavior. Redis failures always fail open. Manual sample runs bypass the processed-post cache. Sofascore caching is unchanged. This change does not add QStash, Workflow, Vector, Search, distributed locks, or rate limiting.

The default is safe without credentials:

```text
UPSTASH_REDIS_MODE=off
```

When active, the generated n8n workflow uses Upstash's HTTPS REST API directly from HTTP Request nodes. No `@upstash/redis` dependency is planned. Generated workflow JSON may contain environment-variable expressions but never real credentials.

## ECC preflight and research

- ECC is available through the installed local skill catalog and plugin surface. The ECC `search-first` skill is present at `/home/louistran/.codex/plugins/cache/ecc/ecc/2.2.0/skills/search-first/SKILL.md` and was read before repository changes. The `omx` CLI binary is not on PATH; no OMX CLI workflow was substituted.
- ECC search-first research confirmed that n8n HTTP Request nodes can call Upstash REST directly with a Bearer token. The planned API is `POST <REST_URL>/pipeline` with ordered `[["GET", key], ...]` and `[["SET", key, value, "EX", ttl], ...]` commands. Missing GETs return `result: null`; pipeline responses must be checked entry-by-entry for errors and exact cardinality.
- Official references: [Upstash REST API](https://upstash.com/docs/redis/features/restapi), [n8n HTTP Request credentials](https://docs.n8n.io/integrations/builtin/credentials/httprequest/), and [n8n HTTP Request node](https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.httprequest/).

## Locked implementation design

1. Normalize `UPSTASH_REDIS_MODE`, REST URL/token presence, and a positive bounded TTL using existing project-style helpers. Missing or invalid active configuration becomes an off/pass-through decision; no secret is committed. Use the key namespace `ftm:v1:processed-post:x:<external_post_id>` and terminal values `ignored` or `merged`.
2. After the twscrape live collector normalizes posts, batch lookup commands through Upstash `/pipeline` before `Persist raw posts`. A valid non-null marker skips that post. Off mode, manual sample runs, malformed responses, HTTP errors, timeouts, auth/rate-limit/server errors, unexpected cardinality, and any ambiguous result pass affected posts through unchanged. RapidAPI is retired from the generated main workflow.
3. After `Mark non-transfer ignored` succeeds, and after `Persist merged reports and revisions` (including its merge transaction) succeeds, deduplicate external IDs and batch `SET ... EX <TTL>` commands through `/pipeline`. Redis writes are non-fatal and cannot block preferred-source handling, enrichment, probability, digest reservation, or Discord. Failed Qwen validation and failed PostgreSQL/merge paths never write a processed key.
4. Keep the existing PostgreSQL path authoritative and unchanged apart from the new optional cache branches. Do not modify Sofascore service caching or add a Redis lock/rate limiter. Regenerate all workflow JSON from `workflow/build-workflows.mjs`; never hand-edit generated JSON.
5. Test in TDD order: unit configuration/key/batch helpers and generated topology first; then fail-open and terminal-write behavior; then extend the isolated mock E2E harness without contacting Upstash; finally run ECC review/security/E2E checks and the repository verification suite.

## Numbered progress

### Step 1 — Baseline, ECC preflight, and design lock — completed

Files changed:

- `docs/plans/2026-08-30-upstash-redis-integration.md` (this progress ledger)

Important decisions:

- Redis is optional and off by default; PostgreSQL remains authoritative.
- Redis lookup is live-collector-only, before raw-post persistence; sample runs bypass it.
- Reads and writes use bounded Upstash REST pipelines; all Redis errors fail open.
- Only successful durable `ignored` or `merged` PostgreSQL transitions populate Redis.
- No SDK, Sofascore change, distributed lock, rate limiter, or other Upstash product is in scope.

Tests/checks and results:

- `node workflow/build-workflows.mjs --check` → passed (`Checked 78 sources and 3 workflow files.`)
- `node --test tests/unit/*.test.mjs` → passed (2 test files, 0 failures)
- `PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml config --quiet` → passed
- `PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml --profile enrichment config --quiet` → passed
- `docker compose -f deploy/n8n/compose.yaml --profile twscrape config --quiet` → passed
- `docker compose -f deploy/support/compose.yaml config --quiet` → passed
- `docker compose -f deploy/qwen3.8-27b/compose.yaml config --quiet` → passed
- Initial `git status --short --branch` was clean on `main`.

Remaining risks:

- The exact n8n node topology and response normalization still need implementation and targeted tests.
- Active-mode credentials and live Upstash connectivity are intentionally unverified; default-off behavior must remain safe.
- Existing migration/E2E infrastructure may expose unrelated pre-existing failures; do not weaken those tests.

Exact next step: Step 2 — read the ECC `tdd-workflow` instructions, add optional configuration and Redis helper primitives with focused unit tests, regenerate/check workflow output, then checkpoint.

### Step 2 — Configuration and Redis primitives — completed

Files changed:

- `workflow/lib.mjs`
- `tests/unit/workflow-lib.test.mjs`
- `deploy/n8n/compose.yaml`

Important decisions:

- Added `normalizeProcessedPostCacheConfig()` with `off` as the default. Active mode requires a valid HTTP(S) REST URL, a non-empty token, and a valid TTL; missing or invalid active settings normalize back to `{ mode: 'off' }` with no credential fields retained.
- Added a positive integer TTL validator with a one-year upper bound (`31_536_000` seconds); the default remains `86_400` seconds.
- Added the exact `ftm:v1:processed-post:x:<external_post_id>` key constructor, decimal X-ID validation, terminal states `ignored`/`merged`, and bounded pipeline command builders. Lookup and SET batches deduplicate IDs and default to 100 commands (never more than 1,000 when a caller supplies a batch size).
- Passed the four Redis environment variables to both the n8n main and external-runner services using safe Compose defaults. No credentials or generated workflow JSON were added.
- Followed ECC `tdd-workflow`: RED test checkpoint `bf82db9`, then the minimal GREEN implementation checkpoint `91334c0`. No Superpowers workflow was used.

Tests/checks and results:

- `node --test tests/unit/workflow-lib.test.mjs` after the test-only change → expected RED (module export missing).
- `node --test tests/unit/workflow-lib.test.mjs` after implementation → passed (1 file, 0 failures).
- `node --test tests/unit/*.test.mjs` → passed (2 files, 0 failures).
- `node workflow/build-workflows.mjs` → passed (`Generated 78 sources and 3 workflow files.`; generated JSON unchanged).
- `node workflow/build-workflows.mjs --check` → passed (`Checked 78 sources and 3 workflow files.`).
- `node --check workflow/lib.mjs && node --check workflow/build-workflows.mjs` → passed.
- `UPSTASH_REDIS_MODE=off PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml config --quiet` → passed.
- Same Compose validation with `--profile enrichment` → passed.
- `git diff --check` → passed.

Remaining risks:

- The helpers are not yet connected to generated n8n lookup/write nodes; fail-open topology and terminal-only population are Step 3/4 work.
- Active mode and real Upstash connectivity remain intentionally unverified; the default/off path has no Redis requests until those nodes are added and tested.
- The one-year TTL ceiling is a local safety bound, not an Upstash service limit.

Exact next step: Step 3 — add generated fail-open Redis lookup nodes before `Persist raw posts` for live collectors, preserve the manual sample bypass, and add topology/response-failure tests before implementation.

### Step 3 — Fail-open Redis lookup before PostgreSQL/Qwen — completed

Files changed:

- `workflow/build-workflows.mjs`
- `workflow/football-transfer-monitor.json` (regenerated)
- `tests/unit/processed-post-cache-workflow.test.mjs`
- `tests/unit/workflow-lib.test.mjs`

Important decisions:

- Incorporated the requirement update that RapidAPI is no longer used: the generated main workflow now has one live collector, twscrape. The selector rejects any value other than `twscrape`; the RapidAPI request/HTTP/parser nodes and branch were removed from generated output.
- Manual sample data is produced directly as raw-post SQL items and connects straight to `Persist raw posts`, so it never enters the Redis preparation, IF, HTTP, or filter nodes.
- Live twscrape posts are grouped by decimal external X ID, duplicate IDs share one GET command, and groups are emitted in bounded batches of 100 commands.
- The Upstash node sends `POST <rest_url>/pipeline` with a JSON command array and a Bearer token read only from `$env`. The filter accepts only HTTP 2xx responses with exact result cardinality and `null`/`ignored`/`merged` result values. Any status, transport error, malformed body, pipeline entry error, invalid marker, or cardinality mismatch emits the affected groups unchanged.
- Redis lookup is gated by normalized active configuration (valid HTTP(S) URL, non-empty token, and bounded positive TTL); all other configuration is routed through the bypass branch without an HTTP request.

Tests/checks and results:

- RED checkpoint `4188239 test: lock twscrape Redis lookup topology` → expected failures before generated nodes existed.
- `node --test tests/unit/processed-post-cache-workflow.test.mjs` → passed (5 tests, 0 failures).
- `node --test tests/unit/*.test.mjs` → passed (3 files, 0 failures).
- `node workflow/build-workflows.mjs` → passed (`Generated 78 sources and 3 workflow files.`).
- `node workflow/build-workflows.mjs --check` → passed (`Checked 78 sources and 3 workflow files.`).
- `node --check workflow/build-workflows.mjs` → passed.
- `git diff --check` → passed.
- GREEN implementation commit `4f17f65 feat: add fail-open Redis lookup to twscrape flow`.

Remaining risks:

- Redis is not yet populated after terminal PostgreSQL `ignored`/`merged` transitions; that is Step 4.
- Active Upstash behavior is covered by mocked code-level responses only; isolated mock-server E2E coverage remains Step 5.
- Legacy library/test and documentation references to the retired RapidAPI path remain to be cleaned up in Step 6; the generated main workflow no longer references it.

Exact next step: Step 4 — add terminal-only, deduplicated, batched, non-fatal Redis SET pipelines after successful PostgreSQL ignored/merge transitions, with RED → GREEN tests and no writes on Qwen or PostgreSQL failure paths.

### Step 4 — Populate Redis only after durable terminal success — completed

Files changed:

- `workflow/build-workflows.mjs`
- `workflow/football-transfer-monitor.json` (regenerated)
- `tests/unit/processed-post-cache-workflow.test.mjs`
- `tests/unit/workflow-lib.test.mjs`

Important decisions:

- The non-transfer PostgreSQL transition now returns the durable row's `external_post_id`; only its successful output reaches the ignored-marker preparation node.
- Qwen transfer reports carry their source `external_post_id`. The merge payload and successful merge SQL output carry deduplicated `processed_post_external_ids`, so a post producing several reports can produce one cache entry.
- Both terminal paths use environment-gated, terminal-state-specific SET preparation (`ignored` or `merged`), exact `ftm:v1:processed-post:x:<id>` keys, `EX <TTL>`, and batches of at most 100 commands.
- The merged branch sends Redis writes through a `continueOnFail` HTTP Request node and resumes from the original durable merge output before preferred-source reset. Redis errors therefore cannot block preferred-source handling, enrichment, probability processing, digest reservation, or Discord. The ignored branch remains terminal after its optional write.
- Qwen validation failures and PostgreSQL/merge failures have no path to a Redis write node. No PostgreSQL retry or deduplication semantics were changed.
- The Qwen parser is parameterized so the external-ID propagation is limited to the live main workflow; the probability backfill generated JSON remains unchanged.

Tests/checks and results:

- RED checkpoint `a2dc207 test: lock terminal Redis population topology` → expected failures for missing terminal write nodes and resume path.
- `node tests/unit/processed-post-cache-workflow.test.mjs` → passed (9 tests, 0 failures), including off mode, deduplication, 100-command batching, terminal states, and merge resume behavior.
- `node tests/unit/workflow-lib.test.mjs` → passed (90 tests, 0 failures), including generated Qwen-to-merge external-ID propagation.
- `node --test tests/unit/*.test.mjs` → passed (3 files, 0 failures).
- `node workflow/build-workflows.mjs` → passed (`Generated 78 sources and 3 workflow files.`).
- `node workflow/build-workflows.mjs --check` → passed (`Checked 78 sources and 3 workflow files.`).
- `node --check workflow/build-workflows.mjs && node --check workflow/lib.mjs` → passed.
- `git diff --check` → passed.
- GREEN checkpoint `637afda feat: populate terminal processed-post Redis markers`.

Remaining risks:

- The isolated mock server does not yet emulate Upstash REST or assert request counts; active/off, hit, outage, malformed-response, and terminal-write E2E cases remain Step 5.
- Active credentials and real Upstash connectivity remain intentionally unverified; default `UPSTASH_REDIS_MODE=off` is still safe.
- Legacy RapidAPI helper/library/test and documentation references remain outside the generated main workflow and must be removed or reconciled during Step 6 after the user's collector retirement requirement.

Exact next step: Step 5 — extend the existing offline mock E2E harness with Upstash `/pipeline` GET/SET behavior and verify off, active hit/miss, outage, malformed response, Qwen/merge failure, and manual-sample bypass scenarios without contacting real Upstash.

### Step 5 — Mock Redis and E2E failure testing — completed

Files changed:

- `tests/e2e/mock/server.mjs`
- `tests/e2e/scenario.mjs`

Important decisions:

- Extended the existing offline mock server with an Upstash-compatible `POST /upstash/pipeline` endpoint. It supports ordered `GET`/`SET ... EX` commands, bounded in-memory TTL state, request/command counters, HTTP 500 injection, and malformed JSON responses; no real Upstash endpoint or credential is contacted.
- The scenario executes the generated Redis preparation/filter/terminal-write Code nodes against that mock. It verifies mode-off zero-request pass-through, active empty-cache miss and successful terminal `merged` write, existing-marker hit filtering with no additional Qwen request, HTTP 500 and malformed-response fail-open, Qwen-invalid no-write, merge-no-output no-write, and manual sample bypass with no Redis request.
- The mock tracks Qwen calls so a cache hit proves the downstream Qwen request count does not increase. The existing isolated harness does not execute a full n8n trigger, so PostgreSQL/merge failure is covered at the generated terminal-preparation boundary (no durable input means no Redis write) plus the Step 4 topology tests; this avoids inventing a fake PostgreSQL implementation.
- Followed ECC `e2e-testing` guidance for deterministic mock-driven checks and retained the default offline Compose path. No Sofascore caching or RapidAPI behavior was added.

Tests/checks and results:

- Test-only RED checkpoint `2e82b9f test: add Upstash mock E2E scenarios` → expected failure before the mock fields/endpoint existed.
- `node --check tests/e2e/mock/server.mjs && node --check tests/e2e/scenario.mjs` → passed.
- Local mock scenario against the updated server → passed (`Mock E2E scenarios passed.`).
- `tests/e2e/run.sh` → passed: disposable PostgreSQL migration/SQL checks, all three workflow imports, mock twscrape/Qwen/Discord/Sofascore checks, and the expanded Redis scenario.
- `git diff --check` → passed.
- GREEN implementation checkpoint `5c61327 feat: emulate Upstash in mock E2E harness`.

Remaining risks:

- The E2E harness validates generated Code-node behavior and HTTP interactions but does not run a complete live-trigger execution through n8n; full PostgreSQL/merge failure injection remains impractical without changing the harness architecture.
- Active Upstash connectivity and production credentials remain intentionally unverified; Redis remains safe with the default `UPSTASH_REDIS_MODE=off`.
- Legacy RapidAPI helper/library, tests, Compose environment, and documentation references remain outside the generated main workflow and must be reconciled in Step 6 per the user's collector-retirement requirement.

Exact next step: Step 6 — update user/deployment/test documentation, reconcile retired RapidAPI references without changing twscrape behavior, add the Redis token to secret scanning, run ECC code review and security review, and execute the complete repository verification suite.

### Step 6 — Documentation, review, security, full verification — completed

Files changed:

- `README.md`
- `workflow/README.md`
- `deploy/n8n/README.md`
- `deploy/n8n/compose.yaml`
- `tests/README.md`
- `tests/e2e/compose.yaml`
- `tests/e2e/mock/server.mjs`
- `tests/e2e/scenario.mjs`
- `tests/unit/processed-post-cache-workflow.test.mjs`
- `tests/unit/workflow-lib.test.mjs`
- `workflow/build-workflows.mjs`
- `workflow/lib.mjs`
- `workflow/football-transfer-monitor.json` (regenerated)
- this progress plan

Important decisions:

- Retired RapidAPI runtime code, mock routes, Compose variables, retry assertions,
  and stale user/deployment/test documentation. The twscrape collector is now
  the sole live X collector; regression assertions intentionally retain the
  no-RapidAPI contract. The tracked `graphify-out` snapshot was not regenerated
  because it is an unrelated stale generated artifact and is not runtime input.
- Documented PostgreSQL as authoritative and Upstash Redis as an optional,
  short-lived, terminal-only acceleration cache with 24-hour default TTL,
  fail-open behavior, sample-run bypass, exact key namespace, and an immediate
  `UPSTASH_REDIS_MODE=off` rollback. Redis remains absent from Sofascore, and no
  SDK, lock, rate limiter, or PostgreSQL retry/deduplication replacement was
  introduced.
- Production Redis URLs are HTTPS-only; loopback HTTP is permitted only for
  `NODE_ENV=test` mock E2E. Ambiguous Redis responses expose only a redacted
  `redis_cache_diagnostic=fail_open` marker so failures remain observable without
  leaking response bodies or credentials.

Tests/checks and results:

- ECC reviewer follow-up: all four prior findings resolved; no remaining code or
  specification blockers. ECC security review: no concrete findings; residual
  trust/token and generated-Code-node coverage risks are recorded below.
- `node workflow/build-workflows.mjs` and `--check`: passed (`78` sources,
  `3` workflows).
- JavaScript syntax checks for changed workflow and E2E files: passed.
- `node --test tests/unit/*.test.mjs`: passed (`3` files, `0` failures).
- Docker Compose validation for base, enrichment, twscrape, support, qwen, and
  E2E configurations: all passed.
- Sofascore image build, Docker smoke test, and isolated fixture suite: passed;
  `89` tests, `0` failures. The generated soccerdata persistence query is
  unchanged since the Step 5 commit.
- Twscrape service suite: passed (`4` tests, `0` failures).
- `tests/e2e/run.sh`: passed, including disposable SQL checks, all workflow
  imports, mock services, and Redis scenarios.
- Secret scan found no generated credential literal; RapidAPI scan found no
  runtime/documentation reference outside intentional regression assertions,
  historical plan text, or the stale graphify snapshot. `git diff --check`
  passed.
- Migration suite was attempted but remains blocked by a pre-existing generated
  enrichment SQL `\gset` cardinality error at
  `/tmp/generated-enrichment-persistence.sql:524` (an earlier run also exposed
  the existing concurrent-claim assertion). No migration, Sofascore code, or
  generated persistence query was changed to mask this unrelated failure.

Remaining risks:

- Active Upstash credentials and production connectivity remain intentionally
  unverified; the default `UPSTASH_REDIS_MODE=off` path is safe.
- Mock E2E executes generated Code-node contracts and workflow import, not a
  complete live-trigger Redis subgraph through n8n; this is documented in
  `tests/README.md`.
- The read/write Redis token is available to trusted n8n and runner Code nodes,
  and a compromised token could suppress posts until TTL expiry; PostgreSQL
  remains durable and authoritative.
- Deployment, publish, commit, and push are intentionally deferred to Step 7.

Exact next step: Step 7 — reread this plan and all changed files, rerun final
verification, optionally perform a non-destructive live connectivity check only
when locally configured credentials can be used without exposing secrets, then
invoke `$deploy-and-push` to regenerate, validate, import, publish, verify,
inspect, stage task files, commit, and push normally without enabling Redis in
production unless valid credentials already exist.

### Step 7 — Deployment and Git completion — merge complete; push pending

Files changed:

- `README.md` (operator monitoring and Redis rollback commands)
- `docs/plans/2026-08-30-upstash-redis-integration.md` (deployment record)

Important decisions:

- Reread the complete plan, `AGENTS.md`, deploy skill, changed implementation
  files, and clean Git state before deployment. Used ECC only; no Superpowers
  workflow was substituted. The requested `$deploy-and-push` procedure was run
  only at this final step.
- Regenerated and validated the stable `football-transfer-monitor` workflow,
  imported it into the existing n8n instance, published the current version,
  and restarted/recreated only `n8n` and `n8n-runner` so the new environment
  defaults are loaded. Named volumes were preserved. The workflow remains
  active as it was before deployment; Redis is still off.
- No real Upstash connectivity check was attempted because no local Upstash
  credentials are configured. No production credential or temporary database
  was created. The ignored local `.env` may contain an obsolete unused
  `RAPIDAPI_KEY` entry, but the Compose configuration and generated workflow do
  not consume RapidAPI.
- Added root-README operations for effective mode/TTL checks in both runtime
  containers, a read-only Upstash `/pipeline` probe, n8n fail-open log and
  execution inspection, PostgreSQL authoritative-state checks, and an
  immediate `UPSTASH_REDIS_MODE=off` recreate rollback. The probe reads only a
  synthetic key and does not print the REST token.

Tests/checks and results:

- Final pre-deploy generation/check, JavaScript syntax checks, 102 Node unit
  tests, and all Compose configuration checks passed.
- Final `tests/e2e/run.sh` passed, including disposable migrations, workflow
  imports, mock services, and Redis scenarios.
- Final migration run reached all existing suites but exited on the known
  unrelated generated-enrichment SQL `\gset` cardinality error at
  `/tmp/generated-enrichment-persistence.sql:524`; no migration or generated
  persistence query changed.
- Final secret scan found no generated credential literal. Final runtime and
  documentation scan found no RapidAPI reference outside intentional regression
  assertions, historical plan text, and the stale graphify snapshot.
- Deployment import reported `Successfully imported 1 workflow.` and publish
  reported the current version published. Post-deploy export verified workflow
  ID `football-transfer-monitor`, active state `true`, 65 nodes, and the
  published version. n8n `/healthz` returned `ok`; both `n8n` and `n8n-runner`
  report `UPSTASH_REDIS_MODE=off`.
- Post-documentation checks passed: `git diff --check`, README shell-block
  syntax (`bash -n`), `node workflow/build-workflows.mjs --check`, and
  `node --test tests/unit/*.test.mjs` (102 tests, 0 failures). A live
  non-mutating container check confirmed both runtime containers report
  `mode=off ttl=86400`.
- After explicit user authorization, `git merge origin/main --no-edit` completed
  cleanly as merge commit `5f4227d`; it preserved the remote GMT+7 wording and
  the task's Redis documentation. Post-merge generation/check, all 102 unit
  tests, and `git diff --check` passed. The branch is clean and currently
  `ahead 18` of `origin/main`.
- Git was clean before the deployment-record edit; `git diff --check` passed
  after it. The deployment-record commit was created locally. The first
  normal push was rejected because `origin/main` advanced by one unrelated
  README-only commit. No force-push or rebase was performed.

Remaining risks:

- Redis remains intentionally inactive until valid production values are added
  to the ignored deployment environment: `UPSTASH_REDIS_MODE=active`, an HTTPS
  REST URL, a token, and an approved TTL. Recreate `n8n` and `n8n-runner` after
  that controlled activation; no activation was performed here.
- The mock E2E suite exercises generated Code-node contracts and HTTP behavior,
  not a full live-trigger Redis subgraph. PostgreSQL remains authoritative if
  Redis is unavailable or compromised.
- The unrelated migration harness `\gset` failure remains for a separate
  follow-up.
- The workflow does not persist a separate cache hit-rate counter; use n8n
  execution item counts and the Upstash console for cache observability, with
  PostgreSQL queries as the durable processing check.
- The normal push has not yet been run after the authorized merge. The deployed
  n8n state is unaffected by this Git-history operation.

Exact next step: Push `main` normally, verify the remote is synchronized, then
record the final push result and completion status here.
