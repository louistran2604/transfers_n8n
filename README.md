# Football Transfer Monitor

An n8n workflow that collects 20 recent X posts from 78 configured transfer sources every six hours, extracts structured reports with local Qwen, stores them in PostgreSQL, and sends one restart-safe Discord digest. X collection is explicitly selectable between a persistent `twscrape` service and the retained RapidAPI collector. Fixture-tested player enrichment uses `soccerdata==1.9.1` with Sofascore; first-time setup remains fail-safe with enrichment off, while the current production deployment runs in `active` mode.

The live schedule is `00:00`, `06:00`, `12:00`, and `18:00` GMT+7.

## What the project does

```text
Schedule or manual trigger
  → recover interrupted deliveries
  → register the workflow run
  → upsert the 78 configured X sources
  → request the latest 20 posts for each source
  → ignore pure retweets and persist raw posts
  → extract and validate transfer reports with local Qwen
  → merge matching reports and create material revisions
  → optionally resolve and persist fail-open player enrichment
  → reserve one digest in PostgreSQL
  → send one confirmed Discord webhook request
  → finalize the delivery and workflow run
```

The repository includes:

- Generated n8n main and error workflows with no embedded credential values.
- A strict Qwen prompt and JSON Schema plus a generated four-tier source registry.
- Idempotent PostgreSQL writes, material revisions, retry state, and digest reservation.
- Pinned n8n, task-runner, PostgreSQL, llama.cpp, private `twscrape`, and private optional Sofascore enrichment Docker services.
- Dependency-free unit tests, transaction-rolled-back SQL tests, and an isolated mock E2E stack.

X account and post IDs remain strings. Direct and quoted posts are processed, pure retweets are ignored, and every raw post/source link is retained even when matching reports are merged.

Each run captures one rolling six-hour collection window. Posts older than the window start or newer than the run start are rejected before persistence and Qwen extraction, and only reports updated inside that same window are eligible for a new digest.

## Requirements

- Ubuntu or another Linux host with Docker Engine and Docker Compose.
- NVIDIA Container Toolkit and a supported NVIDIA GPU for local Qwen.
- Node.js 20 or newer for workflow generation and unit tests.
- `curl`, `jq`, `sha256sum`, and `nvidia-smi` for model acceptance tests.
- A dedicated X account's `auth_token` and `ct0` cookies for live `twscrape` collection, or a RapidAPI key for live RapidAPI collection.
- Discord credentials when performing live delivery.

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
X_COLLECTOR=twscrape
TWSCRAPE_AUTH_TOKEN=<dedicated-x-auth-token>
TWSCRAPE_CT0=<dedicated-x-ct0>
# RAPIDAPI_KEY=<rapidapi-key> # required only when X_COLLECTOR=rapidapi
PLAYER_ENRICHMENT_MODE=off
DISCORD_TRANSFERS_WEBHOOK_URL=<transfer-digest-webhook>
DISCORD_ERRORS_WEBHOOK_URL=<error-alert-webhook>
```

Never paste real values into workflow JSON, documentation, screenshots, logs, command output, or commits.

### 1a. Configure the dedicated X cookies

1. Sign in to `x.com` with the dedicated collection account, open browser developer tools, then open **Application** or **Storage** → **Cookies** → `https://x.com`.
2. Copy only the `auth_token` and `ct0` cookie values into the ignored `deploy/n8n/.env` variables above. Do not paste them into a terminal command or this repository.
3. Keep `X_COLLECTOR=twscrape`. The service copies the values into its internal Docker volume at startup; no workflow JSON or public port receives them.

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
docker compose --profile twscrape build twscrape
docker compose --profile twscrape up -d
docker compose ps
docker compose logs --tail=100 n8n
docker compose exec -T twscrape python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).read().decode())"
cd ../..
```

Open n8n at `http://localhost:5678`. The service and external task runner use matching pinned n8n `2.31.6` images.

The scraper has no host port. Its health check runs inside Docker and reports only service status and the active-account count.

Build and dark-deploy the optional enrichment service while the mode remains off:

```bash
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml build sofascore-enrichment
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml up -d sofascore-enrichment
docker compose -f deploy/n8n/compose.yaml exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2).read().decode())"
```

The enrichment service joins only `transfers_net`, publishes no host port, receives no database or application credentials, and is not an n8n startup dependency.

### 5. Generate and import workflows

The generator reads all 78 accounts directly from `docs/journalist_list.md`, validates every X ID as a decimal string, and embeds the source registry, prompt, and schema:

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

Use **Manual sample run** first. It bypasses only the live collector, inserts deterministic sample X responses, and then uses the real PostgreSQL, Qwen, merge, digest, and Discord path.

The sample path sends to `DISCORD_TRANSFERS_WEBHOOK_URL`. Its rows are persistent test data, so use a test webhook/database when you do not want sample reports mixed with live data.

After the sample path succeeds:

1. Run **Manual run** only after the selected collector is configured.
2. Confirm the selected collection node returns posts or structured per-source errors without aborting the run.
3. Confirm Qwen validation, report persistence, digest reservation, and Discord finalization are green.
4. Activate the main workflow to enable the four scheduled daily runs.

Workflow activation enables the scheduled transfer monitor. Player enrichment is controlled separately by `PLAYER_ENRICHMENT_MODE`; keep first-time and unreviewed deployments at `off`, then use the rollout procedure below when enabling the already approved `active` production path.

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

Only senior men's football is in scope. Known women's-football players are listed in [workflow/womens-football-blacklist.txt](workflow/womens-football-blacklist.txt), one name or spelling variant per line. After adding a name, regenerate and re-import the main workflow:

```bash
node workflow/build-workflows.mjs
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json
```

The generator appends the blacklist to the Qwen prompt. Do not edit the generated workflow JSON manually.

Club and player spelling variants, plus sibling groups, are maintained in [workflow/entity-aliases.json](workflow/entity-aliases.json). Add a canonical name and its known aliases there, then regenerate and re-import the workflow. Aliases are applied before report persistence and digest selection; sibling groups are supplied to Qwen so a shared surname is not automatically merged with the wrong player.

Classification precedence during merging is:

```text
contract renewal
→ rejected/failed
→ loan
→ official/confirmed
→ advanced negotiations
→ rumor
```

Reports are grouped by canonical player/current-club/destination direction. The best source wins, missing values can be filled from lower-tier sources, and conflicting values remain in `normalized_data.conflicts`. A revision is created only when the material snapshot changes.

### Player enrichment

`PLAYER_ENRICHMENT_MODE` has three values:

| Mode | Provider work | PostgreSQL enrichment | Discord |
| --- | --- | --- | --- |
| `off` | None | None | Transfer-only |
| `shadow` | Resolve/fetch | Persist | Transfer-only |
| `active` | Resolve/fetch | Persist | Append eligible enrichment |

A missing or invalid value behaves as `off`. Context, service, validation, and enrichment-persistence failures rejoin digest candidate loading. If core PostgreSQL is healthy, even complete enrichment failure still sends one transfer-only digest.

Identity resolution uses a known provider ID when available. Otherwise, it requires an exact or configured player alias plus an independent club discriminator. The resolver considers both the reported current club and destination club, and treats only safe trailing organization suffixes such as `AFC`, `CF`, `CP`, `FC`, and `SC` as equivalent. It never falls back to player name alone; low scores and close duplicate-name candidates remain unresolved or ambiguous.

The provider request is capped at 25 distinct player groups. Before applying that cap, the workflow uses the same broad priority as the digest: digest-eligible reports first, then confirmed moves, Romano/Ornstein reports, huge rumors, €70m/£70m rumors, source tier/reliability, classification, and confidence. This prevents database ID order from excluding a digest-visible high-priority player.

Eligible enrichment can include:

- Profile: current club, nationality, age, primary position, and Sofascore market value.
- Profile details: date of birth, height, and preferred foot.
- Competition statistics: appearances, minutes, goals, assists, starts, minutes per appearance, expected goals, expected assists, and average rating.
- Other statistics: yellow/red cards, goalkeeper clean sheets, and saves.

Enrichment does not enter the transfer material hash. Profile or statistics refreshes create no transfer revision and cannot resend a delivered revision. In `active`, failure-gated stale attached-player profiles and statistics may render only within 72 hours of provider retrieval; explicitly unattached profiles may render within 7 days. Stale content is labeled. Null, failed, unavailable, ambiguous, unresolved, or expired enrichment is omitted, leaving the original transfer-only story without an error or empty heading.

### Discord digest

Each story includes every meaningful non-null extracted detail that fits:

- Club direction, classification, and move type.
- Fee, add-ons, release clause, contract length, and contract expiry.
- Loan end, purchase option/obligation, and sell-on percentage.
- Medical status, agreement status, confidence, and linked source.

Values such as `unknown` and `not_reported` are omitted. Before formatting, candidates are deduplicated by revision ID and canonical player/destination, so simultaneous links to different destinations remain separate stories. A material update appears as a new entry in the next digest, unless an `official_confirmed` story for that player/destination was sent in the previous seven days; `rejected_failed` always bypasses that cooldown. The digest ranks confirmed transfers first, then Fabrizio Romano or David Ornstein reports, Qwen-marked huge rumors between major clubs, reported €70m/£70m rumors, and all other transfer news. It admits the first 15 distinct stories, then up to three extra stories only when they are confirmed or reported by Romano/Ornstein. It never exceeds 18 stories and also enforces Discord’s 25-field, 1,024-character field, and 6,000-character aggregate embed limits.

When valid enrichment exists, it appears below the transfer facts under `**Player profile & statistics**` and before the linked source. Competition statistics use one compact dynamic line, for example:

```text
Serie A 25/26 - all clubs: 28 app · 2,184 min · 12 G · 7 A · 24 starts · 78 min/app · 10.42 xG · 6.18 xA · 7.31 rating
```

Primary and formerly advanced metrics share that line; there is no separate `Advanced:` label. Fresh statistics containing only card or goalkeeper values still retain a `Competition Season - all clubs` context line before `Other:`.

The formatter budgets enrichment before admitting each story into the embed. It tries whole groups in this order: compact profile, merged competition statistics, profile details, then other statistics. An oversized group is skipped without stopping smaller later groups, source links remain last and untruncated, and no empty enrichment heading is emitted. Under the 6,000-character aggregate limit, fully budgeted enriched stories may reduce the number of stories included rather than silently stripping valid enrichment from already admitted stories.

### Retry and delivery safety

RapidAPI retries up to five times and Qwen retries up to three times. Retry timing honors `Retry-After` and rate-reset headers with bounded exponential backoff. The `twscrape` service uses one shared API instance, a persistent SQLite account database, two concurrent timeline tasks, a 30-second source timeout, and a five-minute batch timeout. A failed or rate-limited source returns a structured error while successful sources continue.

A revision is reserved in PostgreSQL before the Discord request. The workflow sends one webhook request with `wait=true` and records the returned Discord message ID only after success. If n8n stops after sending but before recording the response, recovery changes `sending` to `unknown` and never automatically resends it. This prefers a possible missed digest over a duplicate message.

Discord retries are allowed only after an explicit HTTP `429` or `5xx`. An interrupted request is not proof that Discord rejected it.

A pending delivery keeps the exact Discord payload reserved on its first attempt. Retries reuse that frozen payload; later profile/statistics refreshes do not mutate it or add enrichment retroactively.

## Operations

### Service status and logs

```bash
docker compose -f deploy/support/compose.yaml ps
docker compose -f deploy/qwen3.6-27b/compose.yaml ps
docker compose -f deploy/n8n/compose.yaml ps
docker compose -f deploy/n8n/compose.yaml logs -f n8n
docker compose -f deploy/n8n/compose.yaml --profile twscrape logs -f twscrape
docker compose -f deploy/n8n/compose.yaml logs --tail=200 sofascore-enrichment
docker compose -f deploy/qwen3.6-27b/compose.yaml logs -f llama
```

Check PostgreSQL and Qwen directly:

```bash
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'pg_isready --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'
curl --fail http://127.0.0.1:8081/health
docker compose -f deploy/n8n/compose.yaml exec -T twscrape python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).read().decode())"
nvidia-smi
```

### X collector recovery and switching

If the scraper health check returns unavailable or source errors report `account_unavailable`, obtain fresh `auth_token` and `ct0` values from the dedicated account, update only ignored `deploy/n8n/.env`, then run:

```bash
docker compose -f deploy/n8n/compose.yaml --profile twscrape up -d --force-recreate twscrape
```

Do not delete the `twscrape_accounts` volume during normal recovery. The service updates the stored account only when the local cookie values change.

To use the retained RapidAPI path, set `X_COLLECTOR=rapidapi`, provide `RAPIDAPI_KEY` in the same ignored file, and recreate n8n:

```bash
docker compose -f deploy/n8n/compose.yaml up -d --force-recreate n8n n8n-runner
```

Switch back by setting `X_COLLECTOR=twscrape`, then start the profile command from step 4. `X_COLLECTOR` has no default; an unset or invalid value stops collection before any posts are persisted.

### Safe stop and restart

```bash
docker compose -f deploy/n8n/compose.yaml down
docker compose -f deploy/qwen3.6-27b/compose.yaml down
docker compose -f deploy/support/compose.yaml down
```

These commands preserve the n8n and PostgreSQL volumes and the downloaded GGUF model. Do not add `--volumes` unless permanent data deletion is intentional.

Start in dependency order: support, Qwen, then n8n. The workflow’s recovery step handles interrupted run/delivery state on its next execution.

### Enrichment rollout and rollback

The production rollout has completed its provider-policy, offline-suite, live-acceptance, shadow-run, identity/mapping, failure-delivery, and resource gates, and currently runs with `PLAYER_ENRICHMENT_MODE=active`. New installations should still start at `off`; do not infer approval for a different provider, environment, or resource profile.

After setting `PLAYER_ENRICHMENT_MODE=active` in the ignored `deploy/n8n/.env`, deploy the reviewed service and generated main workflow with:

```bash
docker compose -f deploy/n8n/compose.yaml build sofascore-enrichment
docker compose -f deploy/n8n/compose.yaml up -d --force-recreate sofascore-enrichment
docker compose -f deploy/n8n/compose.yaml exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).read().decode())"
docker compose -f deploy/n8n/compose.yaml exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2).read().decode())"
docker compose -f deploy/n8n/compose.yaml up -d --force-recreate n8n
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n publish:workflow --id=football-transfer-monitor
docker compose -f deploy/n8n/compose.yaml restart n8n
curl --fail http://127.0.0.1:5678/healthz
docker compose -f deploy/n8n/compose.yaml logs --tail=100 n8n
```

The import command temporarily deactivates the workflow; publishing and restarting n8n make the new current version active. Confirm the logs contain `Activated workflow "Football Transfer Monitor"`, Compose reports `sofascore-enrichment` as healthy, and `/readyz` reports package, native library, fixture, cache, and worker readiness with a closed circuit. Resource limits must be changed only from measurements.

Rollback is application-first:

1. Set `PLAYER_ENRICHMENT_MODE=off` in ignored `deploy/n8n/.env` and recreate n8n.
2. Confirm the transfer-only reservation/send path in a test environment.
3. Stop `sofascore-enrichment` if needed and restore recorded prior workflow/image artifacts.
4. Retain additive migration 002, normalized snapshots, attempts, and raw cache for diagnosis.
5. Never release digest items or automatically resend an `unknown` delivery.

Do not use `docker compose down --volumes` for rollback. Detailed cache, upgrade, manual override, and retention commands are in [the n8n deployment guide](deploy/n8n/README.md) and [database guide](database/README.md).

## Verification

Run fast checks from the repository root:

```bash
PLAYER_ENRICHMENT_MODE=off node workflow/build-workflows.mjs --check
PLAYER_ENRICHMENT_MODE=off node --test tests/unit/*.test.mjs
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml config --quiet
docker compose -f deploy/n8n/compose.yaml --profile twscrape config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/qwen3.6-27b/compose.yaml config --quiet
```

After building the scraper image, run its unit tests without any X account:

```bash
docker run --rm -v "$PWD/deploy/n8n/twscrape/tests:/tests:ro" --entrypoint python transfers-n8n-twscrape:local -m unittest discover -s /tests -v
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

The mock stack consumes no live X account, RapidAPI, Discord, or Qwen quota. It verifies the `twscrape` response adapter with a partial source failure while retaining RapidAPI retry coverage. Full test details are in [tests/README.md](tests/README.md).

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

The run may have no eligible reports from its rolling six-hour window, the selected revisions may already belong to a digest, or a prior interrupted delivery may now be `unknown`. This is deliberate duplicate prevention. Inspect the relevant PostgreSQL rows before changing any status.

### Discord receives no message

Confirm the **Digest reserved** true branch ran, the webhook environment variable is present inside n8n, and **Send Discord digest once** returned a Discord message object. A false branch with `{ success: true }` means there was no newly reservable digest to send.

## Limitations

- Both collectors request only the latest 20 posts per account; a long outage can permanently miss older posts.
- Live manual tests can consume RapidAPI quota or dedicated X-account capacity and can send real Discord messages.
- Local Qwen extraction quality depends on the model and quantization; strict validation rejects malformed output.
- Sofascore data availability is not guaranteed; provider failures, unsupported competitions, missing seasons, ambiguous identities, and unresolved players intentionally produce transfer-only output.
- `unknown` Discord deliveries require human review because automatic resend could duplicate a message.
- The source registry is fixed at 78 accounts until the generator and documentation are deliberately updated.

## Repository layout

```text
database/      schema, migrations, persistence documentation, and SQL tests
deploy/n8n/    pinned n8n/task-runner image, Compose service, and private twscrape collector
deploy/qwen3.6-27b/  pinned llama.cpp Qwen service and model scripts
deploy/support/      PostgreSQL Compose service
docs/          78-source registry and RapidAPI request/response examples
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
