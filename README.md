# Football Transfer Monitor

An n8n pipeline that collects football-transfer posts from X, extracts structured reports with a local Qwen model, stores revisions in PostgreSQL, and sends a restart-safe Discord digest.

The workflow runs at `00:00`, `06:00`, `12:00`, and `18:00` GMT+7. Each run checks the latest 20 posts from 78 configured sources. X collection can use the private `twscrape` service or the retained RapidAPI collector.

## Start here

| Goal | Go to |
| --- | --- |
| Install the project for the first time | [Quick start](#quick-start) |
| Change sources, aliases, or filter lists | [Editable registries and filters](#editable-registries-and-filters) |
| Rebuild and publish a workflow | [Regenerate, import, and publish](#regenerate-import-and-publish) |
| Understand player statistics | [Player enrichment](#player-enrichment) |
| Check services or diagnose a failure | [Operations](#operations) and [Troubleshooting](#troubleshooting) |
| Run tests before committing | [Verification](#verification) |

### At a glance

```text
Scheduled or manual trigger
  → recover interrupted deliveries
  → register the workflow run
  → collect recent posts from configured X sources
  → reject pure retweets and out-of-window posts
  → extract and validate transfer reports with local Qwen
  → merge matching reports and create material revisions
  → optionally resolve and persist player enrichment
  → reserve one Discord digest in PostgreSQL
  → send the frozen webhook payload once
  → finalize the delivery and workflow run
```

The repository provides:

- Generated main and error n8n workflows with no embedded credential values.
- A strict Qwen prompt, JSON Schema, source registry, and editable filtering rules.
- Idempotent PostgreSQL persistence, material revisions, retry state, and digest reservation.
- Pinned n8n, task-runner, PostgreSQL, llama.cpp, `twscrape`, and optional Sofascore enrichment services.
- Unit, SQL, and isolated mock end-to-end tests.

## Requirements

- Ubuntu or another Linux host with Docker Engine and Docker Compose.
- NVIDIA Container Toolkit and a supported NVIDIA GPU for local Qwen.
- Node.js 20 or newer for workflow generation and unit tests.
- `curl`, `jq`, `sha256sum`, and `nvidia-smi` for acceptance checks.
- A dedicated X account's `auth_token` and `ct0` cookies for `twscrape`, or a RapidAPI key.
- Discord webhook credentials for live delivery.

The supplied Qwen quantization and settings target a 16 GB GPU. Read the [Qwen deployment guide](deploy/qwen3.6-27b/README.md) before changing the model, context size, or GPU settings.

## Quick start

Run commands from the repository root unless a step explicitly changes directory.

### 1. Configure secrets

The repository intentionally has no `.env.example` files. Real `.env` files are ignored by Git. Create the following files locally if they do not exist.

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

Never paste real values into workflow JSON, documentation, screenshots, logs, terminal output, or commits.

For `twscrape`, sign in to `x.com` with a dedicated collection account. In browser developer tools, open **Application** or **Storage** → **Cookies** → `https://x.com`, then copy only `auth_token` and `ct0` into the ignored environment file. The service stores them in its private Docker volume and exposes no host port.

### 2. Start PostgreSQL

```bash
docker network inspect transfers_net >/dev/null 2>&1 || docker network create transfers_net
docker compose -f deploy/support/compose.yaml up -d transfers-postgres
docker compose -f deploy/support/compose.yaml --profile maintenance run --rm transfers-db-migrate
docker compose -f deploy/support/compose.yaml ps
```

PostgreSQL is not exposed to the host. Containers on `transfers_net` connect to `transfers-postgres:5432`.

### 3. Download and start Qwen

```bash
cd deploy/qwen3.6-27b
./scripts/download-model.sh
docker compose up -d
./scripts/test-server.sh
cd ../..
```

Endpoints and model name:

```text
Host health/API: http://127.0.0.1:8081
n8n chat endpoint: http://llama:8080/v1/chat/completions
Model alias: qwen3.6-27b
```

The llama.cpp container remains running, but the model and KV cache unload after 30 idle seconds to release VRAM. The next request reloads the model, so the first extraction after an idle period takes longer.

### 4. Build and start n8n and the X collector

```bash
cd deploy/n8n
docker compose --profile twscrape build twscrape
docker compose --profile twscrape up -d --wait
docker compose ps
docker compose logs --tail=100 n8n
docker compose exec -T twscrape python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).read().decode())"
cd ../..
```

Open n8n at `http://localhost:5678`. The n8n service and external task runner use matching pinned `2.31.6` images.

The scraper health response reports service status and active-account count. Its API remains private to Docker.

### 5. Generate and import the workflows

```bash
node workflow/build-workflows.mjs
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json
```

Import the error workflow first. The generator reads all 78 accounts from `docs/journalist_list.md`, validates their X IDs as decimal strings, and embeds the source registry, prompt, schema, aliases, and filters into the generated workflows.

### 6. Configure the PostgreSQL credential

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

Open both imported workflows, select `Transfers PostgreSQL` on every Postgres node, and save. Save the error workflow before selecting it in the main workflow's **Error Workflow** setting.

If n8n reports `Host not found`, confirm that n8n and PostgreSQL share the Docker network:

```bash
docker network inspect transfers_net
```

### 7. Test, then activate

1. Run **Manual sample run** first. It replaces only live X collection with deterministic sample responses; PostgreSQL, Qwen, merging, digest creation, and Discord remain real.
2. Run **Manual run** only after the selected live collector is configured.
3. Confirm collection, Qwen validation, report persistence, digest reservation, and Discord finalization succeed.
4. Activate the main workflow to enable its four daily scheduled runs.

The sample path writes persistent test rows and sends to `DISCORD_TRANSFERS_WEBHOOK_URL`. Use a test database and webhook if sample data must not mix with production.

Workflow activation and player enrichment are separate. New installations should begin with `PLAYER_ENRICHMENT_MODE=off`; use the reviewed rollout procedure before enabling enrichment.

## Configuration

### Main environment settings

| Setting | Values | Purpose |
| --- | --- | --- |
| `X_COLLECTOR` | `twscrape` or `rapidapi` | Selects the live X collector; no default is assumed. |
| `PLAYER_ENRICHMENT_MODE` | `off`, `shadow`, or `active` | Controls Sofascore fetching, persistence, and Discord rendering. |
| `DISCORD_TRANSFERS_WEBHOOK_URL` | Secret URL | Receives transfer digests. |
| `DISCORD_ERRORS_WEBHOOK_URL` | Secret URL | Receives workflow error alerts. |

An unset or invalid `X_COLLECTOR` stops collection before posts are persisted. A missing or invalid enrichment mode behaves as `off`.

### Editable registries and filters

| File | What to edit |
| --- | --- |
| [`docs/journalist_list.md`](docs/journalist_list.md) | The 78 configured X sources. |
| [`workflow/entity-aliases.json`](workflow/entity-aliases.json) | Club aliases, player aliases, enrichment-only aliases, sibling groups, and common surnames. |
| [`workflow/womens-football-blacklist.txt`](workflow/womens-football-blacklist.txt) | Senior women's football exclusions, one name or spelling variant per line. |
| [`workflow/qwen-response-schema.json`](workflow/qwen-response-schema.json) | Strict extraction response contract. |

For common surnames, add the normalized surname to `common_surnames`. Qwen is then instructed to preserve a stated given name, while the JavaScript filter uses the first name to distinguish unrelated players. It must not invent a missing given name or reorder surname-first names.

After changing a registry or filter, regenerate and validate the workflows. Do not edit generated workflow JSON manually.

### Regenerate, import, and publish

Use this procedure after changing a source, prompt, schema, alias, filter, or workflow generator:

```bash
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n publish:workflow --id=football-transfer-monitor --versionId=<new-version-id>
# Run this only if the publish command requests a restart:
docker compose -f deploy/n8n/compose.yaml restart n8n
```

Import temporarily deactivates the workflow and creates a new draft version. Export or inspect the imported workflow to obtain its new `versionId`, publish that exact version, then confirm activation in the n8n logs.

`PLAYER_ENRICHMENT_MODE=off` is not needed for the two Node commands: the generator and unit tests do not read that variable. Use the prefix only when intentionally overriding Compose configuration or starting services in fail-safe mode. It does not permanently change `deploy/n8n/.env`.

## How the workflow behaves

### Collection window and source trust

Each run uses one rolling six-hour window. Posts older than the window start or newer than the run start are rejected before persistence and extraction. Only reports updated within that same window can enter a new digest.

Direct and quoted posts are processed; pure retweets are ignored. X account IDs and post IDs remain strings. Every raw post and source link is retained when matching reports are merged.

The generated source registry has four tiers:

| Priority | Sources | Reliability |
| --- | --- | ---: |
| 1 | Official Real Madrid and Manchester United accounts | 1.00 |
| 2 | David Ornstein and Fabrizio Romano | 0.95 |
| 3 | Other organizations | 0.80 |
| 4 | Other individual journalists | 0.70 |

Journalist name, source URL, platform, post timestamp, priority, and reliability come from the X response and registry. Qwen cannot overwrite them.

### Extraction, merging, and revisions

Qwen returns `{ transfer_related, reports[] }` matching the [strict schema](workflow/qwen-response-schema.json). Every report property is required. Unknown facts use `null`, classifications and move types use fixed enums, dates use `YYYY-MM-DD`, currencies use ISO three-letter codes, and monetary values use base units.

Only senior men's football is in scope. The generator appends the women's-football blacklist and alias/filter guidance to the Qwen prompt. JavaScript validation and digest filtering remain authoritative.

Classification precedence during merging is:

```text
contract renewal
→ rejected/failed
→ loan
→ official/confirmed
→ advanced negotiations
→ rumor
```

Reports are grouped by canonical player, current club, and destination direction. The best source wins; missing values may be filled from lower-tier sources; conflicts remain in `normalized_data.conflicts`. A new revision is created only when the material transfer snapshot changes.

### Player enrichment

Player enrichment uses the private Sofascore service through `soccerdata==1.9.1`.

| Mode | Provider work | PostgreSQL enrichment | Discord output |
| --- | --- | --- | --- |
| `off` | None | None | Transfer-only |
| `shadow` | Resolve and fetch | Persist | Transfer-only |
| `active` | Resolve and fetch | Persist | Append eligible enrichment |

The current production deployment uses `active`; new installations remain fail-safe at `off`. Context, service, validation, and enrichment-persistence failures rejoin digest candidate loading. If core PostgreSQL is healthy, complete enrichment failure still produces a transfer-only digest.

Identity resolution first uses a known provider ID when available. Otherwise, it requires an exact name or configured player alias plus an independent club discriminator. It considers the reported current and destination clubs, curated club aliases, and only safe trailing organization suffixes such as `AFC`, `CF`, `CP`, `FC`, and `SC`. It never resolves by player name alone; weak or closely matched duplicate candidates remain unresolved or ambiguous.

The SQL selects up to 25 historical retries after excluding current requests, ordered by resolver-version mismatch and oldest attempt. The request builder keeps current reports before historical candidates, applies digest/source/classification/confidence ordering within each set, and enforces the 25-player cap. Historical retries only piggyback on workflow runs that reach the enrichment query.

Eligible data can include:

- Profile: club, nationality, age, primary position, and Sofascore market value.
- Details: date of birth, height, and preferred foot.
- Competition statistics: appearances, minutes, goals, assists, starts, minutes per appearance, expected goals, expected assists, and rating.
- Other statistics: cards, goalkeeper clean sheets, and saves.

Enrichment does not enter the material transfer hash, create a transfer revision, or resend an already delivered revision. Failure-gated stale attached-player data may render for up to 72 hours after provider retrieval; explicitly unattached profiles may render for up to seven days. Stale data is labeled. Null, unavailable, failed, ambiguous, unresolved, or expired data is omitted without an empty heading.

### Discord digest

Each story includes meaningful non-null transfer facts that fit, such as:

- Club direction, classification, move type, confidence, and source.
- Fee, add-ons, release clause, contract length, and contract expiry.
- Loan end, purchase option or obligation, and sell-on percentage.
- Medical and agreement status.

`unknown` and `not_reported` values are omitted. Candidates are deduplicated by revision ID and canonical player/destination, while simultaneous links to different destinations remain separate.

A material update can appear in a later digest. An `official_confirmed` story for the same player and destination is suppressed for seven days after delivery; `rejected_failed` bypasses that cooldown.

Ranking order is confirmed transfers, Romano or Ornstein reports, Qwen-marked huge rumors between major clubs, reported €70m/£70m rumors, then other news. The digest admits 15 distinct stories and up to three extra confirmed or Romano/Ornstein stories. It also obeys Discord's 25-field, 1,024-character field, and 6,000-character embed limits.

When enrichment exists, it appears under `**Player profile & statistics**` before the source. Competition statistics use one compact line:

```text
Serie A 25/26 - all clubs: 28 app · 2,184 min · 12 G · 7 A · 24 starts · 78 min/app · 10.42 xG · 6.18 xA · 7.31 rating
```

There is no separate `Advanced:` line. Card-only or goalkeeper-only statistics retain a `Competition Season - all clubs` context line before `Other:`.

The formatter budgets enrichment before admitting each story. It tries complete groups in this order: profile, competition statistics, profile details, then other statistics. An oversized group is skipped without blocking smaller later groups. Source links remain last and untruncated. Fully enriched stories may reduce the total number of stories rather than losing valid enrichment after admission.

### Retry and delivery safety

RapidAPI retries up to five times and Qwen up to three times. Retry timing honors `Retry-After` and rate-reset headers with bounded exponential backoff. `twscrape` uses one shared API instance, a persistent SQLite account database, two concurrent timeline tasks, a 30-second source timeout, and a five-minute batch timeout. One failed source does not discard successful sources.

PostgreSQL reserves a digest before Discord is called. The workflow sends one webhook request with `wait=true` and records the Discord message ID only after success. If n8n stops after sending but before recording the response, recovery changes the delivery from `sending` to `unknown` and never resends automatically. This favors a possible missed digest over a duplicate.

Discord retries occur only after an explicit HTTP `429` or `5xx`. A pending delivery keeps the exact payload from its first attempt; later enrichment updates cannot change it.

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

Direct health checks:

```bash
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'pg_isready --username "$POSTGRES_USER" --dbname "$POSTGRES_DB"'
curl --fail http://127.0.0.1:8081/health
docker compose -f deploy/n8n/compose.yaml exec -T twscrape \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).read().decode())"
nvidia-smi
```

### Recover or switch the X collector

If `twscrape` reports `account_unavailable`, obtain fresh `auth_token` and `ct0` cookies, update only `deploy/n8n/.env`, then recreate the service:

```bash
docker compose -f deploy/n8n/compose.yaml --profile twscrape up -d --wait --build --force-recreate twscrape
```

Do not delete the `n8n-ftm-twscrape-accounts` volume during normal recovery.

To use RapidAPI, set `X_COLLECTOR=rapidapi`, add `RAPIDAPI_KEY`, and recreate n8n:

```bash
docker compose -f deploy/n8n/compose.yaml up -d --force-recreate n8n n8n-runner
```

To switch back, set `X_COLLECTOR=twscrape` and start the `twscrape` profile again.

### Deploy or disable player enrichment

Build and dark-deploy the private service while keeping first-time mode off:

```bash
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml build sofascore-enrichment
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml up -d sofascore-enrichment
docker compose -f deploy/n8n/compose.yaml exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2).read().decode())"
```

The prefix explicitly starts this command in fail-safe mode even if the shell has another value. It does not edit the `.env` file. The service has no host port, receives no database or application credentials, and is not required for n8n startup.

For an approved active rollout, set `PLAYER_ENRICHMENT_MODE=active` in `deploy/n8n/.env`, deploy the reviewed service and generated workflow, then verify health and activation:

```bash
docker compose -f deploy/n8n/compose.yaml build sofascore-enrichment
docker compose -f deploy/n8n/compose.yaml up -d --force-recreate sofascore-enrichment
docker compose -f deploy/n8n/compose.yaml exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).read().decode())"
docker compose -f deploy/n8n/compose.yaml exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2).read().decode())"
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n import:workflow --input=/workflows/football-transfer-monitor.json
docker compose -f deploy/n8n/compose.yaml exec -T n8n \
  n8n publish:workflow --id=football-transfer-monitor --versionId=<new-version-id>
docker compose -f deploy/n8n/compose.yaml restart n8n
curl --fail http://127.0.0.1:5678/healthz
docker compose -f deploy/n8n/compose.yaml logs --tail=100 n8n
```

Confirm the logs contain `Activated workflow "Football Transfer Monitor"`, Compose reports the enrichment service as healthy, and `/readyz` reports all readiness gates with a closed circuit.

Rollback is application-first:

1. Set `PLAYER_ENRICHMENT_MODE=off` and recreate n8n.
2. Confirm transfer-only reservation and delivery in a test environment.
3. Stop the enrichment service if needed and restore recorded workflow/image artifacts.
4. Retain additive migration 002, snapshots, attempts, and raw cache for diagnosis.
5. Never release digest items or automatically resend an `unknown` delivery.

Do not use `docker compose down --volumes` for rollback. More cache, override, upgrade, and retention procedures are in the [n8n deployment guide](deploy/n8n/README.md) and [database guide](database/README.md).

### Stop and restart safely

```bash
docker compose -f deploy/n8n/compose.yaml down
docker compose -f deploy/qwen3.6-27b/compose.yaml down
docker compose -f deploy/support/compose.yaml down
```

These commands preserve Docker volumes and the downloaded model. Do not add `--volumes` unless permanent deletion is intentional.

Start in dependency order: PostgreSQL, Qwen, then n8n. The next workflow run performs interrupted-state recovery.

## Verification

Run fast checks from the repository root:

```bash
node workflow/build-workflows.mjs --check
node --test tests/unit/*.test.mjs
PLAYER_ENRICHMENT_MODE=off docker compose -f deploy/n8n/compose.yaml config --quiet
docker compose -f deploy/n8n/compose.yaml --profile twscrape config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/qwen3.6-27b/compose.yaml config --quiet
```

`PLAYER_ENRICHMENT_MODE=off` on the Compose validation command checks the fail-safe configuration without changing the active `.env` value. Node generation and tests do not require it.

After building the scraper image, run its tests without a live X account:

```bash
docker run --rm -v "$PWD/deploy/n8n/twscrape/tests:/tests:ro" \
  --entrypoint python n8n-ftm-twscrape:local \
  -m unittest discover -s /tests -v
```

Run PostgreSQL safety tests:

```bash
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql'
docker compose -f deploy/support/compose.yaml exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql'
```

The SQL fixtures run inside transactions and roll back. Run the isolated mock import/end-to-end suite with:

```bash
tests/e2e/run.sh
```

It consumes no live X, RapidAPI, Discord, or Qwen quota. Full coverage details are in [tests/README.md](tests/README.md).

Before committing:

```bash
rg -n --glob '!*.json' '(RAPIDAPI_KEY|DISCORD_.*WEBHOOK_URL|POSTGRES_PASSWORD)=' .
git status --short --ignored
```

Placeholder names in documentation are expected. Real values are not.

## Troubleshooting

### Postgres query says parameters are missing

Generated Postgres nodes use n8n's **Query Parameters** option. Parameterized nodes require `{{ $json.params }}`; parameterless recovery queries must omit it. Regenerate and re-import instead of repairing generated nodes manually.

### Code or HTTP nodes report `access to env vars denied`

Confirm `N8N_BLOCK_ENV_ACCESS_IN_NODE=false` exists in `deploy/n8n/compose.yaml`, then recreate n8n:

```bash
docker compose -f deploy/n8n/compose.yaml up -d --force-recreate n8n
```

### Qwen returns HTTP 400 while loading

The model unloads after 30 idle seconds. Its next request starts a reload. Watch the llama logs while n8n retries:

```bash
docker compose -f deploy/qwen3.6-27b/compose.yaml logs -f llama
```

### Digest reservation returns no delivery ID

The six-hour window may contain no eligible reports, selected revisions may already belong to a digest, or an interrupted delivery may now be `unknown`. This is duplicate prevention. Inspect the related PostgreSQL rows before changing state.

### Discord receives no message

Confirm the **Digest reserved** true branch ran, the webhook exists inside n8n, and **Send Discord digest once** returned a Discord message object. A false branch with `{ success: true }` means no new digest was reservable.

### Player enrichment is missing

Confirm `PLAYER_ENRICHMENT_MODE=active`, the enrichment container is healthy and ready, and the request reached the provider. Missing provider data, unsupported competitions, identity ambiguity, cooldowns, and failures intentionally fall back to transfer-only output. Do not replay a frozen pending Discord payload to add later enrichment.

## Limitations

- Both collectors request only the latest 20 posts per account; a long outage can permanently miss older posts.
- Live manual tests can consume API or dedicated X-account capacity and can send real Discord messages.
- Local Qwen extraction quality depends on the model and quantization; strict validation rejects malformed output.
- Sofascore availability is not guaranteed; unsupported, missing, ambiguous, failed, and expired data produces transfer-only output.
- `unknown` Discord deliveries require human review because an automatic resend could duplicate a message.
- The source registry remains fixed at 78 accounts until the generator and documentation are deliberately updated together.

## Repository map

The project is split by responsibility. Files marked **generated** should be rebuilt from their source files rather than edited directly.

```text
transfers_n8n/
├── README.md                         main setup, behavior, and operations guide
├── database/
│   ├── migrations/                   ordered PostgreSQL schema changes
│   ├── tests/                        transaction-rolled-back SQL safety tests
│   └── README.md                     persistence model and maintenance guide
├── deploy/
│   ├── n8n/
│   │   ├── compose.yaml              n8n, runner, collector, and enrichment stack
│   │   ├── twscrape/                 private X collector service and its tests
│   │   ├── sofascore/                player-enrichment service and its tests
│   │   └── README.md                 deployment, rollback, cache, and override guide
│   ├── qwen3.6-27b/
│   │   ├── compose.yaml              llama.cpp GPU service
│   │   ├── scripts/                  model download and acceptance checks
│   │   └── README.md                 model and GPU deployment guide
│   └── support/
│       └── compose.yaml              PostgreSQL service
├── docs/
│   ├── journalist_list.md            authoritative 78-source list
│   └── ...                           collector examples and supporting notes
├── workflow/
│   ├── build-workflows.mjs           workflow generator; main build entry point
│   ├── lib.mjs                       reusable validation, selection, and formatting logic
│   ├── entity-aliases.json           club/player aliases and surname filter rules
│   ├── womens-football-blacklist.txt senior women's football exclusions
│   ├── qwen-response-schema.json     extraction response contract
│   ├── football-transfer-monitor.json          generated main workflow
│   ├── football-transfer-monitor-errors.json   generated error workflow
│   └── README.md                     workflow contracts and generation details
├── tests/
│   ├── unit/                         dependency-free JavaScript tests
│   ├── migrations/                   generated-query and migration regressions
│   ├── e2e/                          isolated mock stack and import test
│   └── README.md                     complete test guide
└── graphify-out/                     generated knowledge graph and audit report
```

### How the files connect

```text
docs/journalist_list.md ───────────────┐
workflow/entity-aliases.json ──────────┤
workflow/womens-football-blacklist.txt ├─→ workflow/build-workflows.mjs
workflow/qwen-response-schema.json ────┤          │
workflow/lib.mjs ──────────────────────┘          ├─→ football-transfer-monitor.json
                                                  └─→ football-transfer-monitor-errors.json

database/migrations/ ─→ PostgreSQL schema used by the generated workflows
deploy/n8n/          ─→ runs the generated workflows and private helper services
tests/               ─→ checks source logic, generated SQL, imports, and delivery safety
```

In practice:

1. Edit source lists, rules, schema, or reusable logic under `docs/` and `workflow/`.
2. Run `node workflow/build-workflows.mjs` to refresh both generated JSON files.
3. Run the checks in [Verification](#verification).
4. Import and publish the generated workflow using [Regenerate, import, and publish](#regenerate-import-and-publish).

Focused documentation:

- [Workflow generation and contracts](workflow/README.md)
- [PostgreSQL persistence](database/README.md)
- [n8n deployment](deploy/n8n/README.md)
- [Qwen deployment and GPU checks](deploy/qwen3.6-27b/README.md)
- [Automated tests](tests/README.md)
