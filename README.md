# Football Transfer Monitor

Self-hosted n8n pipeline that collects football-transfer posts from X, extracts structured reports with a local Qwen model, stores restart-safe revisions in PostgreSQL, and sends Discord digests.

The workflow runs at `00:00`, `06:00`, `12:00`, and `18:00` in `Asia/Ho_Chi_Minh`. Each run reads the latest 20 posts from 78 configured sources.

## How it works

```text
X accounts (twscrape or RapidAPI)
  -> n8n filtering and normalization
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
| `twscrape` or RapidAPI | X post collection |
| Sofascore service | Optional player profile and statistics enrichment |

## Requirements

- Linux with Docker Engine and Docker Compose.
- NVIDIA Container Toolkit and a supported NVIDIA GPU. The supplied Qwen quantization targets 16 GB VRAM.
- Node.js 20 or newer for workflow generation and JavaScript tests.
- `curl`, `jq`, `sha256sum`, and `nvidia-smi` for model checks.
- A dedicated X account's `auth_token` and `ct0` cookies, or a RapidAPI key, plus two Discord webhooks.

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
```

To use RapidAPI instead, set `X_COLLECTOR=rapidapi`, add `RAPIDAPI_KEY`, and keep non-secret placeholder values for both `TWSCRAPE_*` variables. Compose validates those variables while parsing the inactive profile.

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

For RapidAPI, omit `--profile twscrape`. Open n8n at `http://localhost:5678`.

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

Run **Manual sample run** first. It writes persistent sample rows and can send a real Discord message, so use test credentials if production data must stay clean. Run **Manual run** only after the selected live collector works. Activate the main workflow after both paths succeed.

## Configuration

| Variable | Values | Purpose |
| --- | --- | --- |
| `X_COLLECTOR` | `twscrape`, `rapidapi` | Select the live X collector; it must be explicit. |
| `PLAYER_ENRICHMENT_MODE` | `off`, `shadow`, `active` | Disable enrichment, persist it without rendering, or render it. Defaults safely to `off`. |
| `DISCORD_TRANSFERS_WEBHOOK_URL` | Secret URL | Transfer digest destination. |
| `DISCORD_ERRORS_WEBHOOK_URL` | Secret URL | Workflow failure destination. |

Changing `PLAYER_ENRICHMENT_MODE` requires recreating n8n. Keep it `off` until the rollout gates in the [n8n deployment guide](deploy/n8n/README.md) have passed.

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

1. Regenerate both JSON files.
2. Run the checks below.
3. Import the error workflow, then the main workflow.
4. Reassign the PostgreSQL credential if n8n requests it.
5. Publish or activate the reviewed workflow in n8n.

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

```bash
docker compose -f deploy/support/compose.yaml ps
docker compose -f deploy/qwen3.8-27b/compose.yaml ps
docker compose -f deploy/n8n/compose.yaml ps
docker compose -f deploy/n8n/compose.yaml logs -f n8n
docker compose -f deploy/qwen3.8-27b/compose.yaml logs -f llama
```

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

```text
database/             PostgreSQL migrations, safety tests, and data-model guide
deploy/n8n/           n8n, external runner, twscrape, and Sofascore services
deploy/qwen3.8-27b/   pinned llama.cpp GPU deployment and model scripts
deploy/support/       PostgreSQL Compose project
docs/                 authoritative X source registry
tests/                unit, migration, container, and mock end-to-end tests
workflow/             generator, reusable logic, extraction inputs, and generated JSON
```

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
