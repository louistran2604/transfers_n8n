# Tests

Run these from the repository root in this order:

```bash
node workflow/build-workflows.mjs --check
node --test tests/unit/*.test.mjs
docker compose -f deploy/n8n/compose.yaml config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/qwen3.6-27b/compose.yaml config --quiet
```

Run PostgreSQL tests against the normal support service after configuring `deploy/support/.env`:

```bash
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql'
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql'
```

Run isolated mock E2E/import validation:

```bash
tests/e2e/run.sh
```

It starts disposable PostgreSQL, mock RapidAPI/Qwen/Discord endpoints, and the pinned n8n image; runs the SQL safety tests; imports both workflows; then verifies duplicate/retry/invalid-response/Discord-limit/interrupted-delivery scenarios. Its cleanup removes only the `transfers-e2e` test volume.

Before a commit, scan tracked files for obvious secret assignments and inspect ignored state:

```bash
rg -n --glob '!*.json' '(RAPIDAPI_KEY|DISCORD_.*WEBHOOK_URL|POSTGRES_PASSWORD)=' .
git status --short --ignored
```
