# Football Transfer Monitor

Self-hosted n8n pipeline that collects football-transfer posts from X, extracts structured reports with a local Qwen model, stores restart-safe revisions in PostgreSQL, and sends Discord digests.

The workflow runs at `00:00`, `06:00`, `12:00`, and `18:00` GMT+7. Each run reads the latest 20 posts from 78 configured sources.

## How it works

```text
X accounts (twscrape)
  -> n8n filtering and normalization
  -> optional Upstash Redis processed-post lookup (live runs only)
  -> local Qwen3.8-27B extraction
  -> PostgreSQL merge, revision, and delivery reservation
  -> optional Sofascore player enrichment
  -> Discord digest
```

The main workflow also has manual live and sample triggers. The sample trigger replaces X collection with fixed posts, but still uses the configured PostgreSQL database, Qwen service, and Discord webhook.

| Component | Role |
| --- | --- |
| n8n `2.31.6` plus external runner | Orchestration and JavaScript/Python task execution |
| PostgreSQL 16 | Source posts, merged reports, revisions, retries, and delivery state |
| llama.cpp plus Qwen3.8-27B | Local structured transfer extraction |
| `twscrape` | X post collection |
| Sofascore service | Optional player profile and statistics enrichment |

PostgreSQL is the authoritative durable state for raw posts, processing,
deduplication, retries, reports, revisions, and delivery. Upstash Redis is an
optional short-lived acceleration cache only; Redis is never required for
correctness and is not used by the Sofascore service.

## Requirements

- Linux with Docker Engine and Docker Compose.
- NVIDIA Container Toolkit and a supported NVIDIA GPU. The supplied Qwen quantization targets 16 GB VRAM.
- Node.js 20 or newer for workflow generation and JavaScript tests.
- `curl`, `jq`, `sha256sum`, and `nvidia-smi` for model checks.
- A dedicated X account's `auth_token` and `ct0` cookies, plus two Discord webhooks.

## Quick start

Run these commands from the repository root.

### 1. Create local environment files

The repository intentionally has no `.env.example` files. Create these ignored files locally and never commit their real values.

`deploy/support/.env`:

```dotenv
POSTGRES_USER=transfers_app
POSTGRES_PASSWORD=<long-random-password>
```

`deploy/n8n/.env` for a `twscrape` collector:

```dotenv
N8N_RUNNERS_AUTH_TOKEN=<long-random-token>
X_COLLECTOR=twscrape
TWSCRAPE_AUTH_TOKEN=<dedicated-x-auth-token>
TWSCRAPE_CT0=<dedicated-x-ct0>
PLAYER_ENRICHMENT_MODE=off
DISCORD_TRANSFERS_WEBHOOK_URL=<transfer-digest-webhook>
DISCORD_ERRORS_WEBHOOK_URL=<error-alert-webhook>
UPSTASH_REDIS_MODE=off
UPSTASH_REDIS_REST_URL=
UPSTASH_REDIS_REST_TOKEN=
UPSTASH_REDIS_POST_TTL_SECONDS=86400
```

Redis remains disabled with `UPSTASH_REDIS_MODE=off`. To activate the
acceleration cache, set `UPSTASH_REDIS_MODE=active` and provide the REST URL
and token. Keep the token only in the ignored environment file.

### 2. Start PostgreSQL and apply migrations

```bash
docker network inspect transfers_net >/dev/null 2>&1 || docker network create transfers_net
docker compose -f deploy/support/compose.yaml up -d transfers-postgres
docker compose -f deploy/support/compose.yaml --profile maintenance run --rm transfers-db-migrate
```

PostgreSQL has no host port. Other containers reach it at `transfers-postgres:5432` on `transfers_net`.

### 3. Download and start Qwen

```bash
cd deploy/qwen3.8-27b
./scripts/download-model.sh
docker compose up -d
./scripts/test-server.sh
cd ../..
```

The host health endpoint is `http://127.0.0.1:8081/health`. n8n uses `http://llama:8080/v1/chat/completions` with model alias `qwen3.8-27b`.

### 4. Generate the workflows and start n8n

```bash
node workflow/build-workflows.mjs
docker compose -f deploy/n8n/compose.yaml --profile twscrape up -d --wait --build
```

Open n8n at `http://localhost:5678`.

### 5. Import both workflows

Import the error workflow first:

```bash
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json
```

### 6. Add the PostgreSQL credential

In n8n, create a Postgres credential named exactly `Transfers PostgreSQL`:

```text
Host: transfers-postgres
Port: 5432
Database: transfers_net
User: POSTGRES_USER from deploy/support/.env
Password: POSTGRES_PASSWORD from deploy/support/.env
SSL: disabled
SSH tunnel: off
```

Assign it to every Postgres node in both workflows. Save the error workflow, select it in the main workflow's **Error Workflow** setting, then save the main workflow.

### 7. Test before activating

Run **Manual sample run** first. It writes persistent sample rows and can send a real Discord message, so use test credentials if production data must stay clean. Sample runs bypass the processed-post Redis lookup. Run **Manual run** only after the twscrape collector works. Activate the main workflow after both paths succeed.

## Configuration

| Variable | Values | Purpose |
| --- | --- | --- |
| `X_COLLECTOR` | `twscrape` | Select the live X collector; it must be explicit. |
| `UPSTASH_REDIS_MODE` | `off`, `active` | Enable the optional processed-post acceleration cache; defaults to `off`. |
| `UPSTASH_REDIS_REST_URL` | HTTPS REST URL | Upstash Redis REST endpoint; used only in active mode. |
| `UPSTASH_REDIS_REST_TOKEN` | Secret token | Upstash REST bearer token; never commit it. |
| `UPSTASH_REDIS_POST_TTL_SECONDS` | Positive integer | Cache TTL; defaults to 86,400 seconds (24 hours). |
| `PLAYER_ENRICHMENT_MODE` | `off`, `shadow`, `active` | Disable enrichment, persist it without rendering, or render it. Defaults safely to `off`. |
| `DISCORD_TRANSFERS_WEBHOOK_URL` | Secret URL | Transfer digest destination. |
| `DISCORD_ERRORS_WEBHOOK_URL` | Secret URL | Workflow failure destination. |

Changing `PLAYER_ENRICHMENT_MODE` requires recreating n8n. Keep it `off` until the rollout gates in the [n8n deployment guide](deploy/n8n/README.md) have passed.

### Processed-post acceleration cache

In active mode, live twscrape posts are looked up in Upstash through bounded
HTTPS REST `/pipeline` batches before PostgreSQL persistence. A valid terminal
marker skips the post; misses and every Redis error fail open to the existing
PostgreSQL/Qwen path. Keys use
`ftm:v1:processed-post:x:<external_post_id>` and values are `ignored` or
`merged`.

Markers are written only after PostgreSQL has durably recorded the terminal
state, with the configured TTL (24 hours by default). Failed Qwen validation,
PostgreSQL, or merge operations never create a marker. Set
`UPSTASH_REDIS_MODE=off` and recreate `n8n` plus `n8n-runner` before the
next run to disable Redis; PostgreSQL behavior is unchanged. Sofascore
continues using its existing local persistent cache and TTLs.

Edit project behavior through these source files:

| File | Purpose |
| --- | --- |
| [`docs/journalist_list.md`](docs/journalist_list.md) | Authoritative 78-source X registry. |
| [`workflow/entity-aliases.json`](workflow/entity-aliases.json) | Club/player aliases, sibling groups, and common surnames. |
| [`workflow/womens-football-blacklist.txt`](workflow/womens-football-blacklist.txt) | Senior women's football exclusions. |
| [`workflow/qwen-system-prompt.md`](workflow/qwen-system-prompt.md) | Extraction instructions. |
| [`workflow/qwen-response-schema.json`](workflow/qwen-response-schema.json) | Strict Qwen response contract. |

## Changing the workflow

`workflow/build-workflows.mjs` is the source of truth for both workflow JSON files. Do not hand-edit generated JSON.

```bash
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
```

After a source, rule, prompt, schema, or generator change:

```bash
# Regenerate and validate both generated workflows.
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
node --test tests/unit/*.test.mjs

# Import the error workflow first, then the main workflow.
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json

# Publish the imported drafts and reload n8n triggers.
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n publish:workflow --id=football-transfer-monitor-errors
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n publish:workflow --id=football-transfer-monitor
docker compose -f deploy/n8n/compose.yaml restart n8n
```

Reassign the PostgreSQL credential if n8n requests it before publishing.

## Verification

Fast offline checks:

```bash
node workflow/build-workflows.mjs --check
node --test tests/unit/*.test.mjs
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml config --quiet
docker compose -f deploy/n8n/compose.yaml --profile twscrape config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/qwen3.8-27b/compose.yaml config --quiet
```

The full suite includes isolated PostgreSQL migrations, fixture-backed Python services, and a mock end-to-end n8n import/run. It does not need live X, Discord, Qwen, or Sofascore access. See [tests/README.md](tests/README.md).

## Operations

### Check service health and logs

Run these from the repository root. The optional services only appear when their Compose profile is enabled.

```bash
docker compose -f deploy/support/compose.yaml ps transfers-postgres
docker compose -f deploy/n8n/compose.yaml ps n8n n8n-runner
docker compose -f deploy/n8n/compose.yaml --profile twscrape ps twscrape
docker compose -f deploy/n8n/compose.yaml --profile enrichment ps sofascore-enrichment
curl --fail http://127.0.0.1:5678/healthz
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'pg_isready --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'
docker compose -f deploy/n8n/compose.yaml --profile enrichment exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2).read().decode())"
```

Use separate terminals when following logs:

```bash
docker compose -f deploy/n8n/compose.yaml logs --since=15m --follow n8n
docker compose -f deploy/n8n/compose.yaml --profile enrichment logs --since=15m --follow sofascore-enrichment
docker compose -f deploy/qwen3.8-27b/compose.yaml logs --since=15m --follow llama
```

Open `http://localhost:5678/executions` for node-level n8n execution details. The queries below show the application state recorded by the workflow.

### Monitor the processed-post cache

Redis is an acceleration layer, not a processing ledger. In an n8n execution,
compare the item counts entering `Prepare processed-post Redis lookup` with the
items leaving `Filter processed-post Redis hits`; a valid hit is removed before
`Persist raw posts`. A Redis outage or ambiguous response leaves the post in
the normal path and adds `redis_cache_diagnostic=fail_open` to the item. Use the
Upstash console for request volume, latency, errors, and memory; use PostgreSQL
for durable processing state.

```bash
# Confirm the effective non-secret mode and TTL in both runtime containers.
for service in n8n n8n-runner; do
  docker compose -f deploy/n8n/compose.yaml exec -T "$service" \
    sh -c 'printf "%s: mode=%s ttl=%s\\n" "$HOSTNAME" "${UPSTASH_REDIS_MODE:-off}" "${UPSTASH_REDIS_POST_TTL_SECONDS:-86400}"'
done

# Read-only Upstash probe: GET a synthetic key without printing the token.
(
  set -a
  . deploy/n8n/.env
  set +a
  if [ "${UPSTASH_REDIS_MODE:-off}" = active ]; then
    curl --fail --silent --show-error --max-time 5 \
      -H "Authorization: Bearer ${UPSTASH_REDIS_REST_TOKEN}" \
      -H 'Content-Type: application/json' \
      --data '[ ["GET", "ftm:v1:processed-post:x:0"] ]' \
      "${UPSTASH_REDIS_REST_URL%/}/pipeline" | jq .
  else
    echo "UPSTASH_REDIS_MODE=${UPSTASH_REDIS_MODE:-off}; Redis probe skipped."
  fi
)

# Inspect recent n8n messages for Redis HTTP failures.
docker compose -f deploy/n8n/compose.yaml logs --since=1h n8n \
  | grep -Ei 'redis|upstash|fail_open|processed-post' || true

# PostgreSQL remains authoritative: watch terminal state and retry backlog.
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --command "
SELECT processing_state, count(*) AS posts
FROM raw_posts
WHERE platform = '\''x'\''
GROUP BY processing_state
ORDER BY processing_state;
"'
```

To disable Redis immediately, set `UPSTASH_REDIS_MODE=off` in the ignored
`deploy/n8n/.env` and recreate both runtime containers. The shell override is a
safe emergency rollback for the current recreate; persist the `.env` change
before the next one:

```bash
UPSTASH_REDIS_MODE=off docker compose -f deploy/n8n/compose.yaml \
  up -d --force-recreate n8n n8n-runner
```

### Inspect recent runs and failures

```bash
# Recent application runs. A non-succeeded status needs investigation.
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --command "
SELECT id, workflow_name, external_execution_id, status, started_at, finished_at
FROM workflow_runs
ORDER BY started_at DESC
LIMIT 20;
"'

# Unresolved workflow failures, newest first.
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --command "
SELECT failure.id, failure.operation_name, failure.error_class,
       failure.error_message, failure.occurrences, failure.last_seen_at,
       run.workflow_name, run.external_execution_id
FROM failures AS failure
LEFT JOIN workflow_runs AS run ON run.id = failure.workflow_run_id
WHERE failure.resolved_at IS NULL
ORDER BY failure.last_seen_at DESC
LIMIT 50;
"'
```

### Check player-enrichment outcomes

```bash
# Count every recorded enrichment outcome.
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --command "
SELECT status, count(*) AS attempts
FROM player_enrichment_attempts
GROUP BY status
ORDER BY attempts DESC, status;
"'

# Inspect the latest enrichment outcomes and errors by reported player.
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --command "
SELECT attempt.started_at, attempt.status, attempt.retryable,
       attempt.next_retry_at, attempt.error_code, attempt.error_message,
       report.reported_player_name, report.current_club_name,
       report.destination_club_name
FROM player_enrichment_attempts AS attempt
LEFT JOIN transfer_reports AS report
  ON report.id = attempt.transfer_report_id
ORDER BY attempt.started_at DESC
LIMIT 50;
"'
```

Treat `provider_failure`, `rate_limited`, `timeout`, and `schema_failure` as enrichment service failures. `unresolved`, `ambiguous`, `deferred`, `unsupported_competition`, `missing_season`, `club_conflict`, and `unattached` are recorded outcomes; check `retryable` and `next_retry_at` to see whether another attempt is scheduled. With `PLAYER_ENRICHMENT_MODE=off`, zero enrichment attempts and provider calls are expected.

Stop services without deleting data:

```bash
docker compose -f deploy/n8n/compose.yaml down
docker compose -f deploy/qwen3.8-27b/compose.yaml down
docker compose -f deploy/support/compose.yaml down
```

Do not add `--volumes` unless permanent deletion is intentional. Start again in dependency order: PostgreSQL, Qwen, then n8n.

## Safety behavior

- Pure retweets and posts outside the rolling six-hour window are rejected before extraction.
- Material transfer changes create new revisions; replaying the same data does not.
- PostgreSQL reserves and freezes a Discord payload before the webhook call.
- A delivery interrupted after the network write becomes `unknown` and is never resent automatically.
- Enrichment failures fall back to a transfer-only digest when core PostgreSQL remains healthy.

## Repository layout

Refresh this snapshot from the repository root with `tree`. It omits Git data, local agent/runtime metadata, ignored environment files, caches, and generated graph output:

```bash
tree -a -L 4 \
  -I '.git|.codex|.opencode|.agents|graphify-out|node_modules|__pycache__|*.pyc|.env'
```

```text
.
├── database/                         # PostgreSQL schema, migrations, and SQL safety tests
│   ├── migrations/                   # Ordered additive schema changes
│   └── tests/                        # Transaction-rolled-back database regressions
├── deploy/                           # Container definitions for each runtime component
│   ├── n8n/                          # n8n, external runner, X collector, and enrichment
│   │   ├── runners/                  # Runner support files (currently empty)
│   │   ├── sofascore/                # Private player-enrichment service
│   │   │   └── tests/                # Enrichment unit, fixture, and live-acceptance tests
│   │   │       └── fixtures/         # Offline provider response fixtures
│   │   └── twscrape/                 # Private X collection service and tests
│   │       └── tests/                # Collector service tests
│   ├── qwen3.8-27b/                  # Pinned llama.cpp/Qwen GPU deployment
│   │   ├── models/                   # Downloaded GGUF model files
│   │   ├── scripts/                  # Model download, extraction, and server checks
│   │   └── tests/                    # Extraction fixtures
│   └── support/                      # PostgreSQL Compose project
├── docs/                             # Human-maintained source documentation
│   └── plans/                        # Planning artifacts (currently empty)
├── services/                         # Additional service placeholders
│   └── transfermarkt-scraper/        # Reserved Transfermarkt scraper service
├── tests/                            # Cross-component test harnesses
│   ├── docker/                       # Container smoke tests
│   ├── e2e/                          # Isolated mock n8n end-to-end tests
│   │   └── mock/                     # Mock HTTP dependencies
│   ├── migrations/                   # Migration and generated-query checks
│   └── unit/                         # Dependency-free JavaScript tests
└── workflow/                         # Generator inputs, reusable logic, and n8n JSON
```

Key root files: `README.md` is the operator guide, `AGENTS.md` is the repository work contract, and `LICENSE` is the project license. Generated workflow JSON belongs under `workflow/`; edit its source files and regenerate it instead of editing the JSON directly.

Detailed guides:

- [Workflow generation and contracts](workflow/README.md)
- [PostgreSQL persistence](database/README.md)
- [n8n deployment, enrichment rollout, and rollback](deploy/n8n/README.md)
- [Qwen deployment and GPU checks](deploy/qwen3.8-27b/README.md)
- [Complete test suite](tests/README.md)

## Current limitations

- Each collector requests only the latest 20 posts per account, so a long outage can miss older posts.
- Live manual runs consume collector capacity and may send real Discord messages.
- Extraction quality depends on the local model; malformed output is rejected by strict validation.
- Sofascore data may be missing, ambiguous, stale, or unavailable; transfer delivery continues without it.
- `unknown` Discord deliveries require human review because retrying could duplicate a message.
