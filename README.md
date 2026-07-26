# Football Transfer Monitor

An n8n workflow that collects 20 recent X posts from 77 configured transfer sources every six hours, extracts structured reports with local Qwen, stores them in PostgreSQL, and sends one restart-safe Discord digest.

The live schedule is `00:00`, `06:00`, `12:00`, and `18:00` in `Asia/Ho_Chi_Minh`.

## What the project does

```text
Schedule or manual trigger
  → recover interrupted deliveries
  → register the workflow run
  → upsert the 77 configured X sources
  → request the latest 20 posts for each source
  → ignore pure retweets and persist raw posts
  → extract and validate transfer reports with local Qwen
  → merge matching reports and create material revisions
  → reserve one digest in PostgreSQL
  → send one confirmed Discord webhook request
  → finalize the delivery and workflow run
```

The repository includes:

- Generated n8n main and error workflows with no embedded credential values.
- A strict Qwen prompt and JSON Schema plus a generated four-tier source registry.
- Idempotent PostgreSQL writes, material revisions, retry state, and digest reservation.
- Pinned n8n, task-runner, PostgreSQL, and llama.cpp Docker services.
- Dependency-free unit tests, transaction-rolled-back SQL tests, and an isolated mock E2E stack.

X account and post IDs remain strings. Direct and quoted posts are processed, pure retweets are ignored, and every raw post/source link is retained even when matching reports are merged.

## Requirements

- Ubuntu or another Linux host with Docker Engine and Docker Compose.
- NVIDIA Container Toolkit and a supported NVIDIA GPU for local Qwen.
- Node.js 20 or newer for workflow generation and unit tests.
- `curl`, `jq`, `sha256sum`, and `nvidia-smi` for model acceptance tests.
- RapidAPI and Discord credentials only when performing live collection/delivery.

The supplied Qwen quantization and settings target a 16 GB GPU. Check [the Qwen deployment guide](deploy/qwen3.6-27b/README.md) before changing the model, context size, or GPU options.

## First-time setup

Run all commands from the repository root unless a step changes directory.

### 1. Configure local secrets

This repository intentionally has no `.env.example` files. Existing real-value `.env` files are ignored by Git. If either file is missing, create it locally with your own values:

`deploy/support/.env`:

```dotenv
POSTGRES_USER=transfers_app
POSTGRES_PASSWORD=<long-random-password>
```

`deploy/n8n/.env`:

```dotenv
N8N_RUNNERS_AUTH_TOKEN=<long-random-token>
RAPIDAPI_KEY=<rapidapi-key>
DISCORD_TRANSFERS_WEBHOOK_URL=<transfer-digest-webhook>
DISCORD_ERRORS_WEBHOOK_URL=<error-alert-webhook>
```

Never paste the real values into workflow JSON, documentation, screenshots, or commits.

### 2. Start PostgreSQL

Create the shared network once, start PostgreSQL, and apply all migrations:

```bash
docker network inspect transfers_net >/dev/null 2>&1 || docker network create transfers_net
docker compose -f deploy/support/compose.yaml up -d transfers-postgres
docker compose -f deploy/support/compose.yaml --profile maintenance run --rm transfers-db-migrate
docker compose -f deploy/support/compose.yaml ps
```

PostgreSQL is not exposed to the host. Containers on `transfers_net` reach it at `transfers-postgres:5432`.

### 3. Download and start Qwen

```bash
cd deploy/qwen3.6-27b
./scripts/download-model.sh
docker compose up -d
./scripts/test-server.sh
cd ../..
```

The llama.cpp container stays running, but the model and KV cache unload after 30 idle seconds. This releases VRAM. The next `/v1/chat/completions` request reloads the model automatically, so the first extraction after an idle period takes longer.

Host and container endpoints:

```text
Host health/API: http://127.0.0.1:8081
n8n chat endpoint: http://llama:8080/v1/chat/completions
Model alias: qwen3.6-27b
```

### 4. Build and start n8n

```bash
cd deploy/n8n
docker compose build
docker compose up -d
docker compose ps
docker compose logs --tail=100 n8n
cd ../..
```

Open n8n at `http://localhost:5678`. The service and external task runner use matching pinned n8n `2.16.1` images.

### 5. Generate and import workflows

The generator reads all 77 accounts directly from `docs/journalist_list.md`, validates every X ID as a decimal string, and embeds the source registry, prompt, and schema:

```bash
node workflow/build-workflows.mjs
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json
```

Import the error workflow first. Re-import after changing the generator because the JSON files are generated artifacts.

### 6. Create and map the PostgreSQL credential

In n8n, create a Postgres credential named exactly `Transfers PostgreSQL`:

```text
Host: transfers-postgres
Port: 5432
Database: transfers_net
User: transfers_app (or POSTGRES_USER from deploy/support/.env)
Password: POSTGRES_PASSWORD from deploy/support/.env
SSL: Disable
SSH tunnel: Off
```

If n8n reports `Host not found`, confirm both containers are attached to `transfers_net`:

```bash
docker network inspect transfers_net
```

Open both imported workflows, select `Transfers PostgreSQL` on every Postgres node, and save. Save the error workflow before selecting it in the main workflow’s **Error Workflow** setting.

### 7. Test before activation

Use **Manual sample run** first. It bypasses only the `Collect 20 X posts` RapidAPI node, inserts deterministic sample X responses, and then uses the real PostgreSQL, Qwen, merge, digest, and Discord path.

The sample path sends to `DISCORD_TRANSFERS_WEBHOOK_URL`. Its rows are persistent test data, so use a test webhook/database when you do not want sample reports mixed with live data.

After the sample path succeeds:

1. Run **Manual run** only when a valid RapidAPI key and remaining quota are available.
2. Confirm `Collect 20 X posts` returns real response bodies instead of error objects.
3. Confirm Qwen validation, report persistence, digest reservation, and Discord finalization are green.
4. Activate the main workflow to enable the four scheduled daily runs.

## Workflow behavior

### Sources and reliability

The registry uses four fixed tiers:

| Priority | Sources | Reliability |
| --- | --- | ---: |
| 1 | Official Real Madrid and Manchester United accounts | 1.00 |
| 2 | David Ornstein and Fabrizio Romano | 0.95 |
| 3 | Other organizations | 0.80 |
| 4 | Other individual journalists | 0.70 |

Journalist name, source URL, platform, post timestamp, priority, and reliability come from the X response and registry. Qwen cannot supply or overwrite them.

### Extraction contract

Qwen must return `{ transfer_related, reports[] }` matching [the strict schema](workflow/qwen-response-schema.json). Every report property is required; unknown nullable facts use `null`. Classifications and move types are locked enums, dates use ISO `YYYY-MM-DD`, currencies use ISO three-letter codes, and monetary values use base units.

Classification precedence during merging is:

```text
contract renewal
→ rejected/failed
→ loan
→ official/confirmed
→ advanced negotiations
→ rumor
```

Reports are grouped by normalized player/current-club/destination direction. The best source wins, missing values can be filled from lower-tier sources, and conflicting values remain in `normalized_data.conflicts`. A revision is created only when the material snapshot changes.

### Discord digest

Each story includes every meaningful non-null extracted detail that fits:

- Club direction, identity hint, classification, and move type.
- Fee, add-ons, release clause, contract length, and contract expiry.
- Loan end, purchase option/obligation, and sell-on percentage.
- Medical status, agreement status, confidence, and linked source.

Values such as `unknown` and `not_reported` are omitted. The digest admits 15 normal stories plus up to three extra official/confirmed or tier-1/2 advanced reports. It enforces Discord’s 25-field, 1,024-character field, and 6,000-character aggregate embed limits.

### Retry and delivery safety

RapidAPI retries up to five times and Qwen retries up to three times. Retry timing honors `Retry-After` and rate-reset headers with bounded exponential backoff.

A revision is reserved in PostgreSQL before the Discord request. The workflow sends one webhook request with `wait=true` and records the returned Discord message ID only after success. If n8n stops after sending but before recording the response, recovery changes `sending` to `unknown` and never automatically resends it. This prefers a possible missed digest over a duplicate message.

Discord retries are allowed only after an explicit HTTP `429` or `5xx`. An interrupted request is not proof that Discord rejected it.

## Operations

### Service status and logs

```bash
docker compose -f deploy/support/compose.yaml ps
docker compose -f deploy/qwen3.6-27b/compose.yaml ps
docker compose -f deploy/n8n/compose.yaml ps
docker compose -f deploy/n8n/compose.yaml logs -f n8n
docker compose -f deploy/qwen3.6-27b/compose.yaml logs -f llama
```

Check PostgreSQL and Qwen directly:

```bash
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'pg_isready --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'
curl --fail http://127.0.0.1:8081/health
nvidia-smi
```

### Safe stop and restart

```bash
docker compose -f deploy/n8n/compose.yaml down
docker compose -f deploy/qwen3.6-27b/compose.yaml down
docker compose -f deploy/support/compose.yaml down
```

These commands preserve the n8n and PostgreSQL volumes and the downloaded GGUF model. Do not add `--volumes` unless permanent data deletion is intentional.

Start in dependency order: support, Qwen, then n8n. The workflow’s recovery step handles interrupted run/delivery state on its next execution.

## Verification

Run fast checks from the repository root:

```bash
node workflow/build-workflows.mjs --check
node --test tests/unit/*.test.mjs
docker compose -f deploy/n8n/compose.yaml config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/qwen3.6-27b/compose.yaml config --quiet
```

Run PostgreSQL safety tests:

```bash
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql'
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql'
```

The SQL tests run inside transactions and roll back their fixtures. Run the isolated mock E2E/import suite with:

```bash
tests/e2e/run.sh
```

The mock stack consumes no live RapidAPI, Discord, or Qwen quota. Full test details are in [tests/README.md](tests/README.md).

Before committing:

```bash
rg -n --glob '!*.json' '(RAPIDAPI_KEY|DISCORD_.*WEBHOOK_URL|POSTGRES_PASSWORD)=' .
git status --short --ignored
```

Inspect matches carefully: placeholder variable names in documentation are expected; real values are not.

## Troubleshooting

### Postgres query says parameters are missing

Generated Postgres nodes use n8n’s **Query Parameters** option. It must contain `{{ $json.params }}` on parameterized nodes and must be absent on parameterless recovery queries. Regenerate and re-import the workflow instead of manually repairing every node.

### Code or HTTP nodes report `access to env vars denied`

Confirm `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` exists in `deploy/n8n/compose.yaml`, then recreate n8n:

```bash
docker compose -f deploy/n8n/compose.yaml up -d --force-recreate n8n
```

### Qwen returns 400 while loading

The model unloads after 30 idle seconds. Its next request triggers a reload. Watch `docker compose -f deploy/qwen3.6-27b/compose.yaml logs -f llama`; n8n’s retry path should continue after the server becomes ready.

### Digest reservation returns no delivery ID

The selected revisions may already belong to a digest, or a prior interrupted delivery may now be `unknown`. This is deliberate duplicate prevention. Inspect the relevant PostgreSQL rows before changing any status.

### Discord receives no message

Confirm the **Digest reserved** true branch ran, the webhook environment variable is present inside n8n, and **Send Discord digest once** returned a Discord message object. A false branch with `{ success: true }` means there was no newly reservable digest to send.

## Limitations

- RapidAPI returns only the latest 20 posts per account; a long outage can permanently miss older posts.
- Live manual tests consume RapidAPI quota and can send real Discord messages.
- Local Qwen extraction quality depends on the model and quantization; strict validation rejects malformed output.
- `unknown` Discord deliveries require human review because automatic resend could duplicate a message.
- The source registry is fixed at 77 accounts until the generator and documentation are deliberately updated.

## Repository layout

```text
database/      schema, migrations, persistence documentation, and SQL tests
deploy/n8n/    pinned n8n/task-runner image and Compose service
deploy/qwen3.6-27b/  pinned llama.cpp Qwen service and model scripts
deploy/support/      PostgreSQL Compose service
docs/          77-source registry and RapidAPI request/response examples
tests/         dependency-free unit tests and isolated mock E2E stack
workflow/      prompt, schema, reusable logic, generator, and generated workflows
graphify-out/  generated repository knowledge graph and audit report
```

More focused documentation:

- [Workflow generation and contracts](workflow/README.md)
- [PostgreSQL persistence](database/README.md)
- [n8n deployment](deploy/n8n/README.md)
- [Qwen deployment and GPU checks](deploy/qwen3.6-27b/README.md)
- [Automated tests](tests/README.md)

Never commit local `.env` files, Discord webhook URLs, RapidAPI keys, PostgreSQL passwords, n8n runner tokens, or downloaded model data.
