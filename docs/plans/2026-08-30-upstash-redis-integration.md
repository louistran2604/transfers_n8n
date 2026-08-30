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
2. After both live X collectors normalize posts, batch lookup commands through Upstash `/pipeline` before `Persist raw posts`. A valid non-null marker skips that post. Off mode, manual sample runs, malformed responses, HTTP errors, timeouts, auth/rate-limit/server errors, unexpected cardinality, and any ambiguous result pass affected posts through unchanged.
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

### Step 3 — Fail-open Redis lookup before PostgreSQL/Qwen — pending

### Step 4 — Populate Redis only after durable terminal success — pending

### Step 5 — Mock Redis and E2E failure testing — pending

### Step 6 — Documentation, review, security, full verification — pending

### Step 7 — Deployment and Git completion — pending
