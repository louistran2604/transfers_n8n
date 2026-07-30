# Tests

The default test path is offline and must not contact live Sofascore. Keep enrichment mode off and run these from the repository root in this order:

```bash
PLAYER_ENRICHMENT_MODE=off node workflow/build-workflows.mjs --check
PLAYER_ENRICHMENT_MODE=off node --test tests/unit/*.test.mjs
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml config --quiet
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml --profile enrichment config --quiet
docker compose -f deploy/n8n/compose.yaml --profile twscrape config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/qwen3.6-27b/compose.yaml config --quiet
```

Build the enrichment image and run its fixture-backed characterization tests with networking disabled:

```bash
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml build sofascore-enrichment
docker run --rm --network none --read-only --tmpfs /tmp \
  --entrypoint python transfers-n8n-sofascore-enrichment:local \
  -m unittest tests.test_characterization -v
```

These tests use the checked-in fixture transport. Readiness and fixture tests verify `soccerdata==1.9.1`, the baked native TLS asset, and the inherited public `soccerdata.Sofascore.get()` boundary without making a provider request.

After building the scraper image, run its dependency-free service tests without real X credentials:

```bash
docker run --rm -v "$PWD/deploy/n8n/twscrape/tests:/tests:ro" --entrypoint python transfers-n8n-twscrape:local -m unittest discover -s /tests -v
```

Run PostgreSQL tests against the normal support service after configuring `deploy/support/.env`:

```bash
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql'
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql'
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/003_soccerdata_enrichment.sql'
```

Run isolated mock E2E/import validation:

```bash
tests/e2e/run.sh
```

It starts disposable PostgreSQL, mock `twscrape`/RapidAPI/Qwen/Discord endpoints, and the pinned n8n image; runs the current SQL safety tests; imports both workflows; then verifies a partial `twscrape` source failure, RapidAPI retry behavior, duplicate/retry/invalid-response/Discord-limit/interrupted-delivery scenarios. Its cleanup removes only disposable `transfers-e2e` resources. Milestone 7 expands this harness with fixture-provider enrichment and off/shadow/active data-flow coverage.

## Optional live acceptance

Live Sofascore acceptance is never part of default discovery or future CI. Milestone 7 adds `deploy/n8n/sofascore/tests/live_acceptance.py` as a separately gated, serial, read-only command. Do not run it until that file exists, provider access-policy approval is recorded, and `SOFASCORE_LIVE_ACCEPTANCE=1` is deliberately supplied. Keep database and Discord writes disabled and use a disposable raw cache.

Before a commit, scan tracked files for obvious secret assignments and inspect ignored state:

```bash
rg -n --glob '!*.json' '(RAPIDAPI_KEY|DISCORD_.*WEBHOOK_URL|POSTGRES_PASSWORD)=' .
git status --short --ignored
```
