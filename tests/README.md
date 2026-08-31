# Tests

The default test path is offline and must not contact live Sofascore. Keep enrichment mode off and run these from the repository root in this order:

```bash
PLAYER_ENRICHMENT_MODE=off node workflow/build-workflows.mjs --check
PLAYER_ENRICHMENT_MODE=off node --test tests/unit/*.test.mjs
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml config --quiet
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml --profile enrichment config --quiet
docker compose -f deploy/n8n/compose.yaml --profile twscrape config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/qwen3.8-27b/compose.yaml config --quiet
```

Build the enrichment image and run the complete fixture-backed Python suite with networking disabled:

```bash
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml build sofascore-enrichment
docker run --rm --network none --read-only --tmpfs /tmp \
  --entrypoint python n8n-ftm-sofascore-enrichment:local \
  -m unittest discover -s tests -v
```

These tests use the checked-in fixture transport. Readiness and fixture tests verify `soccerdata==1.9.1`, the baked native TLS asset, and the inherited public `soccerdata.Sofascore.get()` boundary without making a provider request.

After building the scraper image, run its dependency-free service tests without real X credentials:

```bash
docker run --rm -v "$PWD/deploy/n8n/twscrape/tests:/tests:ro" --entrypoint python n8n-ftm-twscrape:local -m unittest discover -s /tests -v
```

Run the isolated PostgreSQL migration, repeat/concurrency, rollback-compatibility, and SQL constraint suite:

```bash
tests/migrations/run.sh
tests/docker/sofascore-smoke.sh
```

Run isolated mock E2E/import validation:

```bash
tests/e2e/run.sh
```

It starts disposable PostgreSQL, mock `twscrape`/Upstash/Qwen/Discord/Sofascore
endpoints, and the pinned n8n image; runs SQL tests 001–004; imports both
workflows; then verifies Redis-off pass-through, active cache hit/miss,
terminal-only writes, Redis outage/malformed-response fail-open, Qwen/merge
no-write paths, manual-sample bypass, off/shadow/active enrichment,
sparse/ambiguous/malformed/timeout/all-failure paths, transfer-only delivery,
Discord limits, and interrupted-delivery recovery. Its cleanup removes only
disposable `transfers-e2e` resources. The Redis assertions execute the generated
Code-node contracts against the mock and validate workflow import separately;
they do not run a full live-trigger Redis subgraph through n8n.

## Optional live acceptance

Live Sofascore acceptance is never part of default discovery or future CI. Run it only after provider access-policy approval is recorded, with both approval gates deliberately supplied. It is serial and read-only, uses a disposable raw cache, and performs no database or Discord writes:

```bash
SOFASCORE_PROVIDER_POLICY_APPROVED=1 SOFASCORE_LIVE_ACCEPTANCE=1 \
  docker compose -f deploy/n8n/compose.yaml run --rm --no-deps \
  --entrypoint python sofascore-enrichment \
  -m unittest tests.live_acceptance -v
```

Before a commit, scan tracked files for obvious secret assignments and inspect ignored state:

```bash
git grep -n -I -E '(UPSTASH_REDIS_REST_TOKEN|DISCORD_.*WEBHOOK_URL|POSTGRES_PASSWORD)=' -- ':!*.json'
git status --short --ignored
```
