# Football Transfer Monitor: Current State

Last updated: 2026-07-26
Project root: `/home/louistran/projects/transfers_n8n`

This document is the handoff for continuing the project in a new chat. It
records the requested behaviour, decisions, completed setup, current runtime
state, known problems, and remaining work. It intentionally contains no secret
values.

## 1. Project goal

Build a production-ready n8n workflow that monitors football transfer news and
sends a structured Discord digest every six hours.

The finished system must:

1. collect recent posts from the supplied football journalists and
   organizations;
2. detect transfer-related reports and classify them;
3. extract normalized transfer terms and source metadata;
4. merge duplicate reports while retaining every useful source;
5. enrich players through a separate Playwright Transfermarkt scraper;
6. persist processed reports so restarts cannot resend old news;
7. send a readable Discord digest; and
8. include retries, rate-limit handling, validation, logs, and failure alerts.

The final deliverables are:

- workflow architecture and node-by-node design;
- importable n8n workflow JSON;
- Playwright scraper service and code;
- PostgreSQL schema;
- environment-variable documentation;
- setup and test instructions; and
- verification that the system is deduplicated, restart-safe,
  rate-limit-aware, and ready to import.

These final deliverables have not been completed yet.

## 2. User and host environment

- User: Louis
- Host OS: Ubuntu 24.04
- Timezone: `Asia/Ho_Chi_Minh`
- GPU: NVIDIA RTX 5060 Ti with 16 GB VRAM
- n8n: self-hosted with Docker
- Supplied n8n version: `2.16.1`
- Repository: `https://github.com/louistran2604/transfers_n8n`
- Default Git branch: `main`

The repository is a monorepo. Do not run `git init` inside any subdirectory.
Git commands can be run from any directory under the project because Git finds
the root `.git/` automatically.

## 3. Locked workflow decisions

### Schedule

- Run at `00:00`, `06:00`, `12:00`, and `18:00`.
- Use timezone `Asia/Ho_Chi_Minh`.
- This is equivalent to every six hours but avoids schedule drift.

### Transfer classifications

- Official/confirmed
- Advanced negotiations
- Rumor
- Rejected/failed
- Contract renewal
- Loan

### Transfer report fields

Normalize:

- player;
- current club and destination club;
- transfer status;
- permanent transfer or loan;
- fee, currency, add-ons, and release clause;
- contract length and expiry;
- loan duration and option or obligation to buy;
- sell-on clause;
- medical status and agreement status;
- journalist;
- source URL;
- platform;
- source timestamp;
- reliability; and
- confidence level.

### Source priority and duplicate policy

When many sources report the same transfer, prefer:

1. official club accounts;
2. David Ornstein or Fabrizio Romano;
3. configured news organizations;
4. other journalists.

Other sources must still be retained as supporting links. Lower-priority
sources should be used in the digest when they report genuinely new
information.

Reports about the same player and transfer direction must be merged. The
database must retain every source and must prevent Discord from receiving the
same report again after a workflow retry or n8n restart.

### Discord limits

- Normal digest maximum: 15 stories.
- May expand to 18 only for official/confirmed reports or high-trust advanced
  negotiations.
- Digest must include transfer details, player data, source links, and a
  confidence level.
- A separate Discord webhook is used for failures.

## 4. Transfermarkt data selection

The user supplied `transfermarkt_fields.pdf` and reduced the desired fields to
the following set.

### Identity

- name;
- birth date;
- age, derived from birth date rather than stored separately;
- birthplace;
- nationalities;
- height;
- positions; and
- preferred foot.

### Current club

- current club;
- squad number;
- joined date;
- contract expiry;
- current market value; and
- market-value date.

### History

- transfer date;
- source club;
- destination club;
- market value at the time of transfer;
- reported fee;
- transfer type; and
- youth clubs.

### Availability

- current injury;
- injury history.

Avoid duplicate fields. Birth date is stored once and age is calculated.
Current market value and historical transfer-time market value are separate
facts and may both be stored.

The scraper must use Playwright as a separate service. It must not bypass
CAPTCHAs, access controls, or anti-bot protections.

## 5. News sources and RapidAPI

`docs/journalist_list.md` currently contains:

- 50 individual journalists;
- 27 organizations;
- 77 total X accounts.

Each row currently has a name, X username, X URL, and numeric user ID. IDs
must be treated as strings in JavaScript and PostgreSQL because several exceed
JavaScript's safe integer range.

The supplied RapidAPI endpoint pattern is:

```text
GET https://twittr-v2-fastest-twitter-x-api-150k-requests-for-15.p.rapidapi.com/user/{numeric_id}/tweets?count=20&username={username}
```

Required headers:

```text
Content-Type: application/json
x-rapidapi-host: twittr-v2-fastest-twitter-x-api-150k-requests-for-15.p.rapidapi.com
x-rapidapi-key: value from RAPIDAPI_KEY
```

Relevant files:

- `docs/rapidapi_request.txt`
- `docs/rapidapi_sample.json`
- `docs/rapidapi_user_request.txt`
- `docs/rapidapi_user_sample.json`

Known issue: the files named `rapidapi_user_*` are another tweets request and
response sample, not a username-to-user-ID lookup. The user now supplies IDs
directly, so an ID lookup endpoint is not required.

Known issue: the David Ornstein sample request uses a numeric ID that does not
match the ID currently listed for `@David_Ornstein`. Treat request files as
examples only and generate live requests from `docs/journalist_list.md`.

## 6. Model service

The language model is:

- repository: `unsloth/Qwen3.6-27B-GGUF`;
- file: `Qwen3.6-27B-UD-IQ3_XXS.gguf`;
- model alias: `qwen3.6-27b`;
- runtime: llama.cpp CUDA server;
- model checksum:
  `5d591dd11918e196a7b7c9d2f02e4390e7264960eb354c72d65e81a9331978f5`.

The service lives in `deploy/qwen3.6-27b/`.

Current configuration:

- container name: `transfers-llama`;
- pinned image:
  `ghcr.io/ggml-org/llama.cpp:server-cuda12-b10103` with an immutable digest;
- host endpoint: `http://127.0.0.1:8081`;
- n8n/container endpoint: `http://llama:8080`;
- OpenAI-compatible n8n base URL: `http://llama:8080/v1`;
- context size: 8192;
- maximum generation: 2048 tokens;
- all GPU layers;
- Flash Attention enabled;
- q8_0 K/V cache;
- one parallel slot;
- fit-to-VRAM enabled with a 1024 MiB target margin;
- reasoning disabled;
- Web UI disabled;
- offline mode enabled;
- host port bound to localhost only; and
- no API key while access stays local and on the private Docker network.

Port 8080 was already occupied by `noivevn-nginx-1`, so the model uses host
port 8081. Containers still use the internal port 8080.

Current runtime check:

- `transfers-llama` is running and healthy;
- host mapping is `127.0.0.1:8081 -> 8080`;
- it is attached to `transfers_net`.

The model download and acceptance-test scripts exist:

- `deploy/qwen3.6-27b/scripts/download-model.sh`
- `deploy/qwen3.6-27b/scripts/test-server.sh`

Known documentation issue: `deploy/qwen3.6-27b/README.md` mentions copying
`.env.example`, but no such file exists. The Compose defaults work without an
environment file. Fix the README reference later or add a service-local
template only if one becomes useful.

## 7. n8n service

The n8n deployment lives in `deploy/n8n/`.

Current containers:

- `n8n_bill`: running, host port 5678;
- `n8n_bill_runner`: running.

Current n8n configuration:

- Compose project name: `bill`;
- n8n container name: `n8n_bill`;
- runner container name: `n8n_bill_runner`;
- timezone: `Asia/Ho_Chi_Minh`;
- external task runners enabled;
- n8n data stored in Docker named volume `bill_n8n_data`;
- n8n joins its default Compose network for the runner;
- n8n also joins external network `transfers_net`;
- the runner remains on the default network;
- local n8n URL: `http://localhost:5678`;
- secure cookies currently disabled because the local URL uses HTTP.

The n8n `.env` supplies:

- `N8N_RUNNERS_AUTH_TOKEN`;
- `RAPIDAPI_KEY`;
- `DISCORD_TRANSFERS_WEBHOOK_URL`;
- `DISCORD_ERRORS_WEBHOOK_URL`.

Compose requires all four values and fails early if any are missing.

Current runtime check:

- `n8n_bill` and `transfers-llama` are the two containers attached to
  `transfers_net`;
- n8n should reach the model at `http://llama:8080`;
- the future scraper should use
  `http://transfermarkt-scraper:3000`;
- the future database should use
  `transfers-postgres:5432`.

Known deployment issue: both n8n Dockerfiles use floating `latest` image tags.
They do not currently pin n8n to the supplied version `2.16.1`. Pin compatible
n8n and runner versions before calling the deployment production-ready.

Known minor issue: `version: "3.8"` in the n8n Compose file is obsolete in
modern Docker Compose and may produce a warning. It does not currently prevent
startup.

## 8. Shared Docker network

The external Docker network is named:

```text
transfers_net
```

It allows containers from separate Compose projects to communicate through
Docker DNS. Each service keeps its own Compose file and lifecycle while
sharing only this network.

Current and planned DNS names:

```text
llama:8080                    current Qwen service
transfermarkt-scraper:3000   planned Playwright service
transfers-postgres:5432      planned PostgreSQL service
```

The host endpoint `127.0.0.1:8081` is for host-side model tests. n8n must use
`llama:8080`, not the host endpoint.

The network currently exists and has two attached containers:

- `n8n_bill`;
- `transfers-llama`.

## 9. Environment-file behaviour

A Compose `.env` file is loaded for variable substitution only when the
Compose command is run from the appropriate project context or explicitly
given an env file. Variables listed under a service's `environment:` section
are then injected into that container.

Each independently run Compose project can have its own local `.env`.
The n8n secrets belong in `deploy/n8n/.env`.

There is no need for a root `.env.example` for runtime operation. The user
chose not to create one. A template may be added later only if documenting
required variables for another machine becomes useful.

## 10. Repository layout

```text
transfers_n8n/
├── README.md
├── current_state.md
├── transfermarkt_fields.pdf
├── docs/
│   ├── journalist_list.md
│   ├── rapidapi_request.txt
│   ├── rapidapi_sample.json
│   ├── rapidapi_user_request.txt
│   └── rapidapi_user_sample.json
├── database/                         currently empty
├── workflow/                         currently empty
├── services/
│   └── transfermarkt-scraper/        currently empty
└── deploy/
    ├── n8n/
    │   ├── .env                      ignored
    │   ├── .gitignore
    │   ├── Dockerfile
    │   ├── compose.yaml
    │   ├── docker-compose.yml.backup ignored
    │   └── runners/Dockerfile
    ├── qwen3.6-27b/
    │   ├── README.md
    │   ├── compose.yaml
    │   ├── models/                   ignored
    │   └── scripts/
    └── support/                      currently empty
```

Git does not track empty directories, so the empty planned directories do not
appear on GitHub yet.

## 11. Git and GitHub state

The repository was initialized once at the project root. No nested Git
repositories were found.

Current commits:

```text
4e73ae1 Organized docs
b9a901b Change section headers to Markdown format
6640863 Add project README
ea8c5b4 Set up football transfer monitoring project
```

At the time this handoff was written:

- local `main` matched `origin/main`;
- the tracked working tree was clean;
- `deploy/n8n/.env` was ignored;
- `deploy/n8n/docker-compose.yml.backup` was ignored;
- `deploy/qwen3.6-27b/models/` was ignored.

The saved GitHub CLI authentication token is currently invalid. This does not
change the already-pushed repository state, but future `gh` operations require:

```bash
gh auth login -h github.com --web
```

The root `.gitignore` excludes:

```text
.env
.env.*
*.gguf
models/
node_modules/
postgres-data/
playwright-report/
test-results/
*.log
*.backup
```

It currently contains an exception for `.env.example`, although no root
`.env.example` exists.

## 12. Secret and credential state

Never print or commit actual secret values.

Configured secret names:

- `RAPIDAPI_KEY`;
- `DISCORD_TRANSFERS_WEBHOOK_URL`;
- `DISCORD_ERRORS_WEBHOOK_URL`;
- `N8N_RUNNERS_AUTH_TOKEN`.

The real n8n `.env` is ignored by both the root ignore rules and
`deploy/n8n/.gitignore`.

Credential scans performed during setup found no literal Discord webhook,
RapidAPI key, or runner-token values in commit-eligible files.

Security history:

- A Discord webhook URL was pasted into the original chat. It must be treated
  as compromised. The user reported replacing/configuring webhooks in the
  ignored `.env`.
- A runner authentication token previously appeared in a sanitized Compose
  file. Rotation was recommended. Confirm that the current token was rotated;
  its rotation status was not verified.

Do not place secrets directly in workflow JSON, Compose files, shell scripts,
documentation, Git history, or Discord messages.

## 13. PostgreSQL decision

PostgreSQL 16 was selected for persistence.

It should run as a separate supporting service under `deploy/support/` and
join `transfers_net` with hostname `transfers-postgres`.

The schema has not been created. It must support:

- source accounts and reliability;
- raw collected posts;
- normalized transfer reports;
- many sources per merged transfer;
- player and Transfermarkt profile data;
- transfer, youth-club, and injury histories;
- digest delivery records;
- idempotency/deduplication keys;
- workflow run logs and failures; and
- retry-safe processing states.

Database writes should use unique constraints and transactions so rerunning a
workflow execution cannot create duplicates or resend a digest.

## 14. Planned Playwright scraper

The scraper has not been implemented. Its intended location is:

```text
services/transfermarkt-scraper/
```

Its deployment should be added to `deploy/support/`.

Required behaviour:

- accept a player profile URL or a validated player identifier;
- use Playwright;
- collect only the approved fields;
- normalize dates, measurements, currency, and club names;
- return validated structured JSON;
- apply low concurrency and delays;
- cache results to reduce repeated page access;
- retry only transient failures;
- stop and alert on CAPTCHA, HTTP 403, or HTTP 429;
- log errors without sensitive data;
- expose a health endpoint; and
- be reachable by n8n as `http://transfermarkt-scraper:3000`.

## 15. Legal and access-control requirements

Before scraping Transfermarkt:

- review its current Terms of Service;
- review its current `robots.txt`;
- check whether the intended pages and automated access are permitted;
- minimize request volume and cache results;
- do not bypass CAPTCHAs, authentication, blocks, or rate limits;
- do not use stealth or proxy rotation to evade protections; and
- stop scraping and notify the error webhook when access is refused.

These risks must be documented in setup instructions rather than hidden.

X data must use the user's existing RapidAPI Twitter/X API. Its current quota,
pricing, and rate-limit headers still need to be confirmed from the active
RapidAPI subscription.

## 16. Work not yet done

The following major components remain:

1. Design the PostgreSQL 16 schema and supporting Compose service.
2. Build and test the Playwright Transfermarkt scraper.
3. Define the Qwen extraction prompt and strict JSON schema.
4. Build the complete n8n workflow and export importable JSON.
5. Run end-to-end tests for deduplication, restart safety, rate limits,
   retries, Discord formatting, and failure notifications.

Also resolve these smaller inconsistencies:

- pin n8n and runner images instead of using `latest`;
- fix the missing `.env.example` reference in the Qwen README;
- update the root README layout because the source files moved into `docs/`;
- treat RapidAPI request samples as examples rather than source-of-truth IDs;
- confirm the runner token was rotated; and
- reauthenticate GitHub CLI before the next GitHub write.

## 17. Recommended next session

Start with PostgreSQL and the supporting Compose project because the workflow's
deduplication and restart safety depend on the schema.

Suggested first request for the next chat:

```text
Read current_state.md and inspect the repository. Plan the PostgreSQL 16
schema and deploy/support/compose.yaml for this football transfer workflow.
Do not edit until you show me the plan and I approve it. Preserve all existing
files, use transfers_net, keep secrets in an ignored local .env, and design
unique constraints for restart-safe deduplication.
```

After PostgreSQL, build the scraper, then the n8n workflow. This order avoids
redesigning the workflow after its persistence model is known.
