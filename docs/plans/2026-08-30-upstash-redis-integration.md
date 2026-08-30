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

### Step 2 — Configuration and Redis primitives — pending

### Step 3 — Fail-open Redis lookup before PostgreSQL/Qwen — pending

### Step 4 — Populate Redis only after durable terminal success — pending

### Step 5 — Mock Redis and E2E failure testing — pending

### Step 6 — Documentation, review, security, full verification — pending

### Step 7 — Deployment and Git completion — pending
