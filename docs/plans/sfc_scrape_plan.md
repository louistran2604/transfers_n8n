# Soccerdata Sofascore Enrichment Plan

## 1. Executive decision

The feature is feasible with **soccerdata 1.9.1 and its Sofascore provider only**, but not through the provider's current high-level public methods alone.

The implemented boundary should be a small, persistent, internal Python HTTP service. It should:

- import and instantiate `soccerdata.Sofascore`;
- use the inherited, documented `BaseRequestsReader.get()` transport and cache;
- call four targeted Sofascore JSON endpoint shapes through that reader;
- normalize nullable player/profile/statistic data behind a versioned local contract;
- never scrape rendered HTML and never use Playwright, Selenium, ScraperFC, a standalone Sofascore package, or another football-data provider.

The high-level `Sofascore` class currently exposes league tables and schedules, not player search, profiles, or player season statistics. The required player data is therefore dependent on undocumented Sofascore JSON endpoint schemas. That is the main feasibility risk and requires fixture tests, schema guards, raw-payload provenance, a package pin, and fail-open workflow integration.

No requested field is guaranteed for every player and league:

- age, minutes per game, the source URL, and retrieval time are derived locally;
- starts, height, preferred foot, proposed market value, xG, xA, and average rating are nullable and were absent in at least some verified responses;
- market value is Sofascore's **proposed** market value, not a guaranteed official valuation;
- all player fields are unsupported by soccerdata's high-level Sofascore methods and require the thin adapter described above.

Enrichment must remain optional. A digest must still be reserved and sent when the service is unavailable, every player is unresolved, the database enrichment write fails, or every field is null.

## 2. Current-state findings

### Existing transfer pipeline

The current six-hour pipeline is:

```text
X collection
  -> Qwen extraction
  -> strict report validation
  -> merge material reports and sources
  -> persist reports/revisions/preferred sources
  -> select undelivered material revisions
  -> construct one bounded Discord digest
  -> reserve/send/finalize delivery
```

Evidence:

- `README.md:3-20` describes X collection, Qwen extraction, PostgreSQL persistence, and Discord delivery. `README.md:33` describes the rolling collection window.
- `workflow/qwen-system-prompt.md:1-15` limits extraction to senior men's football, defines classification precedence, and forbids invented facts.
- `workflow/qwen-response-schema.json:1-76` is a strict schema with `additionalProperties: false`; all report keys exist and nullable values remain null.
- `workflow/build-workflows.mjs:439-460` validates exact Qwen fields and injects source metadata.
- `workflow/build-workflows.mjs:463-506` merges reports by normalized player/current-club/destination identity, sorts sources, chooses preferred values, records conflicts, and constructs a material content hash.
- `workflow/lib.mjs:300-363` handles report deduplication, material snapshots, and revisions.
- `workflow/build-workflows.mjs:677-706` persists merged reports and revisions, resets and sets preferred sources, prepares digest candidates, finds undelivered revisions, builds the digest, and enters the delivery reservation flow.
- `workflow/build-workflows.mjs:754-760` defines the corresponding generated graph connections.

The enrichment insertion point is **after** reports, revisions, and preferred sources have been persisted, and **before** digest candidates are formatted. Enrichment must not be part of the transfer snapshot or its content hash. Refreshing player statistics alone must not create a transfer revision or a Discord delivery.

### Existing idempotency, retry, and failure isolation

- `database/migrations/001_initial_schema.sql:13-258` defines source/raw-item uniqueness, provider-neutral `players`, transfer report/revision uniqueness, preferred-source uniqueness, workflow run state, retry state, failures, and restart-safe digest delivery constraints.
- `database/migrations/001_initial_schema.sql:58-68` already provides the provider-neutral `players` anchor with a unique `identity_key`, display/normalized names, and nullable birth date.
- Revisions are unique by `(transfer_report_id, revision_number)` and `(transfer_report_id, content_sha256)`.
- `database/migrate.sql:3-24` uses `app_schema_migrations` and a PostgreSQL advisory lock. Migration `001` is already historical and must not be rewritten.
- `database/tests/001_dedup_restart_safety.sql:18-307` and `database/tests/002_workflow_safety.sql:14-171` use transaction rollback to verify replay, delivery, and recovery behavior.
- `workflow/lib.mjs:366-380` bounds retry delay at 300 seconds and respects `Retry-After`; Discord retries are limited to 429 and 5xx responses.
- `workflow/lib.mjs:495-498` converts interrupted `sending` deliveries to `unknown` rather than risking duplicate sends.
- `workflow/build-workflows.mjs:631-646` gives the twscrape request a 310-second timeout and `continueOnFail`; the RapidAPI path is bounded.
- `workflow/build-workflows.mjs:668-674` bounds Qwen attempts and records terminal extraction failures.
- `workflow/build-workflows.mjs:700-723` builds, reserves, sends, and finalizes one Discord webhook delivery.

These behaviors are preservation constraints. Enrichment may add its own cache and attempt state, but must not weaken the existing report or delivery keys.

### Discord construction

- `workflow/lib.mjs:418-438` builds each transfer story and preserves the journalist source link.
- `workflow/lib.mjs:445-492` deduplicates and prioritizes at most 15 primary plus 3 secondary stories, emits at most 25 embed fields, truncates names to 256 characters and values to 1,024 characters, and respects Discord's 6,000-character aggregate embed limit.
- `tests/unit/workflow-lib.test.mjs:122-211` covers story priority, formatting, and limits.

Player data must be subordinate to the transfer report and journalist attribution. It is optional text within the existing bounded field, not a second unbounded embed.

### Deployment and service pattern

- `deploy/n8n/compose.yaml:3-67` runs n8n, its task runner, and the optional internal twscrape service on the external `transfers_net` network.
- `deploy/support/compose.yaml:4-48` keeps PostgreSQL and migrations on the same private network.
- `deploy/n8n/twscrape/app.py` is the nearest service pattern: a small Python HTTP process with health handling, persistent local state, structured errors, and no public host port.
- `tests/e2e/compose.yaml`, `tests/e2e/mock/server.mjs`, `tests/e2e/scenario.mjs`, and `tests/e2e/run.sh` provide the existing container and workflow smoke-test surface.

### Failed Transfermarkt/Playwright work

Commit `6e6ceca7450cbb80edde2553804e39937693c645` is titled `Removed player data scraping`. Repository history shows:

- a deleted `transfermarkt_fields.pdf`;
- a now-deleted `current_state.md` design describing a planned `services/transfermarkt-scraper/` service, low concurrency, cache, retries, and stopping on CAPTCHA/403/429;
- historical, pre-release versions of migration `001` containing `transfermarkt_profiles`, `player_transfer_history`, `player_youth_history`, and `player_injury_history`, plus related triggers/retry values.

There is no committed Playwright/Transfermarkt service implementation or service test to migrate. There is also no recorded live bot-detection run; history contains a bot-detection policy, not evidence of an executed failure. The active tree has no Transfermarkt or Playwright dependency, container, or production reference.

Decisions:

- do not restore the deleted PDF, deleted design file, or historical Transfermarkt tables;
- do not rewrite migration `001`;
- do not archive or delete anything from the active production tree because no active implementation remains;
- leave `graphify-out` as unrelated generated repository analysis output; do not regenerate or clean it as part of this feature;
- document the replacement in current README/operations documentation during implementation.

Complete historical-reference disposition:

| Historical path/reference | What history contains | Decision |
| --- | --- | --- |
| `.gitignore` | Removed `playwright-report/` ignore entry | No active browser report exists; do not restore it |
| `README.md` | Planned Playwright/Transfermarkt flow and access policy before `6e6ceca` | Replace only with current Sofascore operations text when the feature is implemented |
| `current_state.md` | Planned empty service, endpoint, fields, access stops, and handoff; later deleted by `cc1aaf6` | Leave deleted |
| `database/README.md` | Descriptions of the removed Transfermarkt profile/history tables | Add new soccerdata tables only; do not restore the old text |
| `database/migrations/001_initial_schema.sql` | Pre-release Transfermarkt tables, triggers, indexes, and retry resource | Preserve the current applied migration byte-for-byte; add migration `002` |
| `transfermarkt_fields.pdf` | User-supplied field reference deleted by `6e6ceca` | Leave deleted |
| Planned `services/transfermarkt-scraper/` | Mentioned as empty in documentation; no committed implementation files | Nothing to delete or archive |

Current-tree searches find no Transfermarkt, Playwright, browser container, or browser dependency reference. Therefore implementation must remove none; claiming otherwise would rewrite history rather than replace active code.

The feature branch and `main` started this investigation at the same commit (`f3dd914`); no separate unfinished implementation was found.

## 3. Verified soccerdata capabilities

### Evaluated release and source

- Package: `soccerdata==1.9.1`
- PyPI release date observed: 2026-07-24
- Wheel SHA-256 observed: `15c135e9995f27535cd26ba360edccdbf664051796675ba2cd5109e0cc63d2bc`
- Git tag: `v1.9.1`
- Tag commit observed: `323169a3acc1378cc8c5318db3bae7de5fe3d14f`
- Supported Python range: `>=3.10,<3.15`

Primary evidence:

- [soccerdata 1.9.1 on PyPI](https://pypi.org/project/soccerdata/1.9.1/)
- [soccerdata v1.9.1 release](https://github.com/probberechts/soccerdata/releases/tag/v1.9.1)
- [Sofascore provider reference](https://soccerdata.readthedocs.io/en/stable/reference/sofascore.html)
- [Base reader reference](https://soccerdata.readthedocs.io/en/latest/reference/base.html)
- [`soccerdata/sofascore.py` at v1.9.1](https://github.com/probberechts/soccerdata/blob/v1.9.1/soccerdata/sofascore.py)
- [Upstream Sofascore tests at v1.9.1](https://github.com/probberechts/soccerdata/blob/v1.9.1/tests/test_Sofascore.py)

The exact release must be hash-locked with its full dependency tree. `soccerdata` currently has a mandatory SeleniumBase dependency for other providers. The Sofascore class itself extends `BaseRequestsReader` and does not need a browser. The service must install the supported dependency tree but must not install a browser binary, start Selenium, or import any soccerdata provider other than `Sofascore`. Installing `soccerdata --no-deps` would be a fragile unsupported packaging shortcut and is rejected.

### Public surface

The provider's high-level public methods are:

```python
soccerdata.Sofascore.read_leagues()
soccerdata.Sofascore.read_seasons()
soccerdata.Sofascore.read_league_table(force_cache=False)
soccerdata.Sofascore.read_schedule(force_cache=False)
```

Upstream tests cover those four operations. There is no `read_player`, player search, profile, or player-statistics method.

`Sofascore` inherits the documented `BaseRequestsReader.get(url, filepath, max_age, no_cache)` transport. Using that method does not make the player endpoints part of the supported high-level provider API: the endpoint paths and response schemas remain undocumented provider internals. The local adapter must be intentionally thin and must not copy `_session`, `_download_and_save`, or other private soccerdata internals.

### Targeted endpoints verified through soccerdata-compatible transport

The feasibility spike used these JSON endpoint shapes:

```text
/search/all?q=<name>
/player/<player_id>
/unique-tournament/<tournament_id>/seasons
/player/<player_id>/unique-tournament/<tournament_id>/season/<season_id>/statistics/overall
```

The production adapter should form the URLs, choose deterministic cache file names, and pass them to `Sofascore.get()`. It must validate returned JSON before normalization.

A cold, unambiguous lookup needs four targeted successful downloads: search, profile, seasons, and overall statistics. It does **not** require a league-wide download. With a confirmed player mapping and competition-season mapping, a refresh needs profile plus statistics at most. A fresh PostgreSQL snapshot requires no provider call.

For comparison, the high-level league-table path needs approximately three downloads, while a 38-round schedule can need approximately 41. Those methods should not be used for per-player enrichment.

An unresolved ambiguous search may inspect at most five football candidate profiles, making the bounded cold worst case eight calls: one search, five profiles, one season list, and one statistics call. The statistics and season calls occur only after one candidate clears the identity threshold.

### Cache and error behavior

- Default cache root: `~/soccerdata/data/Sofascore`.
- The service must set a dedicated persistent data root and volume rather than relying on a container home directory.
- `no_cache=True` bypasses an existing cache but still permits storing the new response.
- `no_store=True` prevents storage.
- Current-season table/schedule operations bypass cache unless `force_cache=True`; the local adapter must set explicit `max_age` values for its own raw files.
- `BaseRequestsReader` defaults to no request delay.
- The inherited transport retries a failed request up to five times without provider-specific exponential backoff or `Retry-After` handling, then raises a generic connection error.
- The inspected `get()` path has no explicit per-request timeout parameter.

The service therefore must add a single-call rate gate, must not add another same-run retry layer, and must enforce the batch deadline by isolating provider work in a replaceable worker process.

### Live spike results

The live read-only spike ran on 2026-07-30:

1. **Kylian Mbappé**
   - Search resolved one football player: Sofascore ID `826643`.
   - Profile: Real Madrid, France, date-of-birth timestamp, forward, 180 cm, right foot, proposed market value `191000000 EUR`.
   - LaLiga 2025/26: tournament `8`, season `77559`, 31 appearances, 29 starts, 2,604 minutes, 25 goals, 23.9453 xG, 5 assists, 6.2019957 xA, and 7.5612903225806 rating.
   - Derived minutes per appearance: `84.0`.

2. **John Smith, duplicate-name case**
   - Search returned 20 mixed-sport results.
   - At least two exact-name football players were present: ID `2544168` (retired English midfielder without a current team) and ID `2332241` (United States goalkeeper at Holy Cross/NCAA).
   - Name-only selection is unsafe and must return `ambiguous` or `unresolved`.

3. **Nguyễn Quang Hải, outside the top five**
   - Profile: ID `845067`, Công An Hà Nội, Vietnam, midfielder, 168 cm, left foot, proposed market value `435000 EUR`.
   - V-League 1 2025/26: tournament `626`, season `78589`, 24 appearances/starts, 2,160 minutes, 3 goals, 6 assists, and 7.4083 rating.
   - xG and xA were absent.
   - The profile's `team.tournament` indicated V-League 2 (`771`), while `primaryUniqueTournament` indicated V-League 1 (`626`) and only the V-League 1 statistics lookup succeeded. League resolution must prefer and validate `primaryUniqueTournament`; it must never blindly use `team.tournament`.

Direct plain `curl` access returned 403 during an independent check. The design must use the soccerdata reader transport as required, not replace it with a second HTTP scraping dependency.

### Field matrix

All normalized fields remain nullable unless explicitly identified as a local invariant.

| Requested field | Available | Soccerdata method/source | Normalization | Fallback behavior |
| --- | --- | --- | --- | --- |
| Canonical player name | Direct, nullable | `/player/<id>` through `Sofascore.get()` | Trim Unicode; preserve provider spelling | Keep report name and mark profile partial |
| Sofascore player ID | Direct | Search/profile path and payload | Store as non-empty text to avoid numeric-width assumptions | No mapping is persisted when unresolved |
| Current club | Direct, nullable | Player profile `team` | Resolve to provider-neutral club and alias | Retain report club evidence; do not invent a provider club |
| Nationality | Direct, nullable | Player profile `country` | Store provider code/name separately when present | Omit from output |
| Age | Derived | Date of birth plus retrieval date | Completed years at `retrieved_at` | Null if date of birth is absent |
| Date of birth | Direct, nullable | Player profile timestamp | UTC calendar date | Null |
| Primary position | Direct, nullable | Player profile `position` | Map provider code to a small display label while retaining raw value | Show raw supported label or omit |
| Height | Direct, nullable | Player profile `height` | Integer centimetres; reject implausible values in schema validation | Null/omit |
| Preferred foot | Direct, nullable | Player profile `preferredFoot` | `left`, `right`, or null; retain unknown raw values only in payload | Null/omit |
| Market value | Direct, nullable | Player profile `proposedMarketValueRaw.value` | Non-negative integer in smallest provider unit as observed; label as proposed value | Null/omit |
| Market-value currency | Direct, nullable | Player profile `proposedMarketValueRaw.currency` | Uppercase ISO-like code; use a symbol only for a known code | Display code or omit value when currency is invalid |
| Source URL | Derived, unstable convenience | Player slug and ID | Build a Sofascore player URL; provider ID remains authoritative | Emit stable `sofascore:<id>` identifier if URL format fails |
| Stable source identifier | Direct/derived | Player ID | `provider=sofascore`, `entity_type=player`, external ID | Required for a resolved mapping |
| Source retrieval timestamp | Local | Service clock after successful normalization | UTC `timestamptz` | Use last-good snapshot time for stale data |
| Competition | Direct context, nullable | `primaryUniqueTournament` plus stored provider mapping | Provider-neutral domestic-league mapping | `unsupported_competition`; omit statistics |
| Season | Direct context, nullable | Tournament seasons endpoint | Provider ID, label, start/end dates where present | Use confirmed stored mapping; otherwise omit stats |
| Appearances | Direct, nullable | Overall statistics `appearances` | Non-negative integer | Null/omit |
| Starts | Direct, nullable | Overall statistics `matchesStarted` | Non-negative integer, not greater than appearances when both exist | Null/omit |
| Minutes played | Direct, nullable | Overall statistics `minutesPlayed` | Non-negative integer | Null/omit |
| Minutes per game | Derived | Minutes divided by appearances | One decimal internally; compact integer display when exact | Null when minutes or appearances are absent/zero |
| Goals | Direct, nullable | Overall statistics `goals` | Non-negative integer | Null/omit |
| Expected goals (xG) | Direct, nullable | Overall statistics `expectedGoals` | Non-negative decimal | Null/omit; never estimate |
| Assists | Direct, nullable | Overall statistics `assists` | Non-negative integer | Null/omit |
| Expected assists (xA) | Direct, nullable | Overall statistics `expectedAssists` | Non-negative decimal | Null/omit; never estimate |
| Average rating | Direct, nullable | Overall statistics `rating` | Decimal retained at provider precision; two-decimal display | Null/omit |
| Other same-call fields | Direct, coverage varies | Same overall-statistics payload | Initially normalize total shots, shots on target, key passes, and big chances created only when present | Store raw payload; keep these out of Discord unless space remains |
| Raw payload/provenance | Direct | Each adapter response | JSON object, endpoint kind, schema version, content hash, cache state | Keep last-good normalized row if new payload is invalid |

“Available” above means observed from the targeted endpoint, not promised by the high-level public Sofascore API.

## 4. Proposed architecture

### Decision

Add a persistent internal service named `sofascore-enrichment` under `deploy/n8n/sofascore/`. It follows the existing twscrape service boundary but does not copy twscrape-specific logic.

```text
                             private transfers_net

  X/Qwen/merge
       |
       v
  n8n persists transfer report + material revision
       |
       v
  PostgreSQL enrichment lookup
       |\
       | \ fresh profile/stats -----------------------------+
       |                                                     |
       +-- missing/stale distinct players                    |
                   |                                         |
                   v                                         |
       POST /v1/enrich (bounded batch)                        |
                   |                                         |
                   v                                         |
       sofascore-enrichment service                           |
         |  supervisor: validation/deadline/health            |
         |  replaceable worker: soccerdata.Sofascore          |
         |  persistent raw HTTP cache volume                  |
         v                                                    |
       targeted Sofascore JSON endpoints                      |
                   |                                         |
                   v                                         |
       normalized per-player success/error result             |
                   |                                         |
                   v                                         |
       PostgreSQL conflict-safe upsert + stale fallback -------+
                   |
                   v
       existing digest candidate query and Discord delivery
```

### Why this boundary

- It matches the proven private-service pattern without adding soccerdata to the JavaScript task runner.
- The Python process and dependency tree are isolated from n8n.
- A persistent raw cache survives container restarts and is shared across six-hour workflow runs.
- The HTTP contract makes fixture-backed testing and schema-change handling explicit.
- n8n remains the only component that needs PostgreSQL credentials and owns durable identity/snapshot state.
- A hung library request can be terminated by replacing the worker process without killing n8n.

Rejected alternatives:

- **Scheduled cache warmer:** it cannot know a newly mentioned player before that digest and adds another schedule/recovery surface. A later optional warm job may call the same service for already-mapped active players.
- **n8n task-runner dependency:** it couples a large Python dependency tree and cache lifecycle to the JavaScript runner and weakens timeout isolation.
- **Direct n8n HTTP calls:** they would bypass soccerdata, duplicate caching/normalization, and violate the provider boundary.
- **Service with PostgreSQL access:** it adds credentials and transaction ownership to the service without a requirement. n8n can batch all reads/writes.
- **Paid football API or automatic fallback provider:** both are outside the required soccerdata/Sofascore-only boundary.

### Request and cache budget

- PostgreSQL profile TTL: 7 days.
- PostgreSQL current-season statistics TTL: 12 hours, so alternating six-hour runs normally reuse data.
- Competition/season mapping TTL: 7 days during a season and mandatory refresh at a detected season boundary.
- Stale profile fallback: up to 30 days.
- Stale current-season-stat fallback: up to 7 days and visibly marked in stored metadata, not Discord text unless operationally useful.
- Raw soccerdata cache uses matching endpoint-specific ages on a persistent volume.
- Fresh DB snapshot: 0 provider downloads.
- Known player and current competition-season, expired data: at most 2 downloads.
- Cold unambiguous player: 4 downloads.
- Cold ambiguous player: at most 8 downloads, with no statistics request until one identity is safe.

Defaults should be conservative:

- one active provider worker;
- at least 1 second between endpoint calls;
- maximum batch of 25 distinct players;
- 45-second provider-work budget and 60-second n8n HTTP timeout;
- no outer same-run retry, because soccerdata already attempts failed downloads;
- a circuit breaker opens after a configurable small run of provider failures and returns stale/error results until a short cooldown expires.

The HTTP supervisor must treat its deadline as authoritative. It should terminate and recreate the single provider worker if the inherited soccerdata transport does not return before the deadline.

## 5. Identity, league, and season resolution

### Player identity algorithm

Resolution order:

1. Use a confirmed manual or prior `(provider, player)` mapping.
2. Search the report's original player name.
3. Keep football player candidates only. Reject other sports and clearly women's, youth, reserve, or non-player results.
4. Fetch at most five candidate profiles.
5. Compare normalized names and current-club evidence. Nationality, position, and a report identity hint may corroborate but may not replace club evidence.
6. Persist a mapping only when the acceptance threshold and runner-up margin pass. Otherwise return `ambiguous` or `unresolved`.

Normalization:

- apply Unicode NFKD and casefolding;
- remove combining accents for comparison while preserving display spelling;
- normalize punctuation and repeated whitespace;
- store original provider/report aliases;
- treat a transliteration as an alias only after manual confirmation or after exact club-backed provider resolution;
- never use edit-distance fuzzy matching as an automatic acceptance rule.

Scoring:

| Evidence | Score |
| --- | ---: |
| Existing confirmed provider ID or manual override | 1.00 |
| Exact normalized canonical name or confirmed alias | 0.55 |
| Exact normalized current club or confirmed club alias | 0.35 |
| Corroborated nationality, position, or explicit report identity hint | 0.10 |

Automatic acceptance requires:

- score `>= 0.90`;
- current-club evidence;
- a margin `>= 0.15` above the next candidate.

Anything else is non-destructive:

- exact name without club: `unresolved`;
- more than one candidate above the threshold or an insufficient margin: `ambiguous`;
- no candidate: `unresolved`;
- a changed provider club conflicting with a locked manual mapping: keep the mapping, record conflict evidence, and refresh the manual queue.

Manual overrides use the database mapping tables, not tracked config containing personal data or a new admin UI. Operations documentation should provide reviewed SQL to insert/update a locked player, club, or competition mapping with an operator note and timestamp. Locked mappings are auditable and are never replaced by an automatic result.

### League resolution algorithm

For the resolved current club:

1. Prefer profile `primaryUniqueTournament`; do not select `team.tournament`.
2. Resolve its provider tournament ID through a stored provider competition mapping.
3. Require the mapping classification to be `domestic_league`, `senior`, and `men`.
4. Require club/team country/category consistency when provider metadata supplies it.
5. Reject stored or provider classifications for cups, continental competitions, national teams, women's competitions, youth/U-age competitions, and reserve/B/II teams.
6. If provider metadata is insufficient, store a candidate mapping as `pending` and return `unsupported_competition`. Do not guess from a similar name.

The top five leagues may be seeded as confirmed provider mappings, but the algorithm is not a five-name allowlist. Any league can be accepted when its provider ID has the same validated, stored classification. The Nguyễn Quang Hải spike proves the need for provider-ID mappings and the `primaryUniqueTournament` rule.

Club aliases are provider-neutral and country-scoped. An alias maps report text such as abbreviations or transliterations to one club; conflicting aliases remain pending for manual review.

### Active season algorithm

1. Load a confirmed, non-expired provider club/competition-season mapping when available.
2. Otherwise fetch the selected tournament's seasons.
3. Prefer the unique season whose provider start/end timestamps contain the retrieval time.
4. If dates are absent, use a unique provider “current” marker when present.
5. If neither is decisive, use the unique latest season that has started only when its ordering and label agree; otherwise return `unsupported_competition`.
6. Persist provider season ID, label, dates, retrieval time, and resolution method.

Club-to-league mappings are season-scoped. Promotion or relegation is detected by refreshing the player profile and mapping at the season boundary; an old season mapping never overrides a new `primaryUniqueTournament`. A manual mapping can resolve incomplete provider metadata.

### Mid-season transfers

Statistics should mean:

> all player appearances across clubs in the selected current club's primary domestic league and active season.

Consequences:

- a same-league transfer shows combined league performance across old and current clubs because the targeted overall endpoint is player + tournament + season;
- a cross-league transfer shows only the new current domestic league, excluding the old league;
- cups, continental matches, and national-team statistics are always excluded.

This is more useful for transfer reporting than “current club only”: it preserves the player's full performance in the league the reader is evaluating and matches the low-cost overall endpoint. The tradeoff is that a same-league total is not a pure current-club split. The API and Discord label must say `scope: selected-league-all-clubs`.

## 6. Database changes

Create one new forward migration:

`database/migrations/002_soccerdata_sofascore_enrichment.sql`

Register it in `database/migrate.sql`. Do not modify `001_initial_schema.sql`.

The migration is transactional and creates the following provider-neutral objects. Every externally supplied text key gets a non-empty check; every JSON payload gets an object check; timestamps use `timestamptz`.

### Tables and constraints

1. `football_data_providers`
   - `id bigint generated always as identity primary key`
   - `provider_key text not null unique`
   - `display_name text not null`
   - `created_at`, `updated_at`
   - seed exactly one row: `sofascore`

2. `player_aliases`
   - `id`, `player_id references players(id) on delete cascade`
   - `alias`, `normalized_alias`, `alias_source`
   - source check: `report`, `provider`, or `manual`
   - `unique (player_id, normalized_alias)`
   - index `(normalized_alias)`

3. `player_provider_mappings`
   - `id`, `player_id`, `provider_id`, `provider_player_id`
   - `status`: `confirmed_auto` or `confirmed_manual`
   - nullable confidence constrained to `[0,1]`
   - `resolution_method`, JSON `match_evidence`, nullable `manual_note`
   - `manual_locked boolean not null default false`
   - `first_seen_at`, `last_verified_at`, `created_at`, `updated_at`
   - `unique (provider_id, player_id)`
   - `unique (provider_id, provider_player_id)`
   - ambiguous/rejected candidates stay in attempt evidence rather than claiming an external identity

4. `football_clubs`
   - `id`, unique `identity_key`, `display_name`, `normalized_name`
   - nullable `country_code`
   - `gender` constrained to `men`, `women`, or `unknown`
   - `team_level` constrained to `senior`, `reserve`, `youth`, or `unknown`
   - timestamps
   - index `(normalized_name, country_code)`

5. `club_aliases`
   - `id`, `club_id`, `alias`, `normalized_alias`, nullable `country_code`, `alias_source`
   - `unique (club_id, normalized_alias, country_code)`
   - lookup index `(normalized_alias, country_code)`

6. `provider_clubs`
   - `id`, `provider_id`, nullable `club_id`, `provider_club_id`, provider display/normalized name
   - nullable country/gender/team-level evidence
   - `mapping_status`: `confirmed_auto`, `confirmed_manual`, `pending`, or `rejected`
   - `mapping_source`, `manual_locked`, JSON `raw_payload`
   - first/last-seen and update timestamps
   - `unique (provider_id, provider_club_id)`
   - partial unique index `(provider_id, club_id) where club_id is not null and mapping_status in ('confirmed_auto', 'confirmed_manual')`

7. `football_competitions`
   - `id`, unique `identity_key`, `display_name`, nullable `country_code`
   - `competition_type`: `domestic_league`, `domestic_cup`, `continental`, `international`, or `other`
   - `gender`: `men`, `women`, or `unknown`
   - `age_level`: `senior`, `youth`, or `unknown`
   - nullable positive `tier`, active flag, timestamps
   - index `(country_code, competition_type, gender, age_level)`

8. `provider_competitions`
   - `id`, `provider_id`, nullable `competition_id`, `provider_competition_id`
   - provider display name, `mapping_status`, `mapping_source`, `manual_locked`
   - JSON `raw_payload`, first/last-seen and update timestamps
   - `unique (provider_id, provider_competition_id)`
   - partial unique index `(provider_id, competition_id) where competition_id is not null and mapping_status in ('confirmed_auto', 'confirmed_manual')`

9. `competition_seasons`
   - `id`, `competition_id`, `season_key`, `display_label`
   - nullable `starts_on`, `ends_on` with end not before start
   - `unique (competition_id, season_key)`
   - index `(competition_id, starts_on desc)`

10. `provider_seasons`
    - `id`, `provider_id`, `provider_competition_mapping_id references provider_competitions(id)`, nullable `competition_season_id`
    - `provider_season_id`, provider label, nullable start/end dates
    - `resolution_method`, `mapping_status`, JSON `raw_payload`
    - `retrieved_at`, `verified_at`, `expires_at`
    - `unique (provider_competition_mapping_id, provider_season_id)`
    - partial index for current lookups on `(provider_competition_mapping_id, expires_at desc)` where confirmed

11. `provider_club_seasons`
    - `id`, `provider_club_mapping_id references provider_clubs(id)`, `provider_season_mapping_id references provider_seasons(id)`
    - `is_primary_domestic boolean`
    - `resolution_method`, `mapping_status`, nullable confidence, JSON evidence
    - `verified_at`, `expires_at`
    - `unique (provider_club_mapping_id, provider_season_mapping_id)`
    - index `(provider_club_mapping_id, expires_at desc)`
    - season scoping prevents a relegated/promoted club's old league from being reused

12. `player_provider_profiles`
    - one current last-good row per `player_provider_mapping_id`
    - normalized nullable fields: canonical name, provider club row, nationality name/code, date of birth, primary position, height cm, preferred foot, proposed market value, currency
    - stable source ID, nullable source URL
    - `retrieved_at`, `fresh_until`, `stale_until`, schema version, 64-character content SHA-256, JSON raw profile
    - checks for non-negative value, uppercase three-letter currency when present, sensible height range, and ordered freshness timestamps
    - `unique (player_provider_mapping_id)`
    - index `(fresh_until)` for batch expiry lookup

13. `player_season_snapshots`
    - `id`, `player_provider_mapping_id`, `provider_competition_mapping_id`, `provider_season_mapping_id`
    - `scope` fixed initially to `selected_league_all_clubs`
    - nullable appearances, starts, minutes, goals, xG, assists, xA, rating
    - nullable low-cost fields: total shots, shots on target, key passes, big chances created
    - minutes per game is derived on read and is not persisted independently
    - `retrieved_at`, `fresh_until`, `stale_until`, schema version, 64-character content SHA-256, JSON raw statistics
    - non-negative stat checks; starts may not exceed appearances when both are present; ordered freshness timestamps
    - `unique (player_provider_mapping_id, provider_competition_mapping_id, provider_season_mapping_id, content_sha256)`
    - latest-snapshot index `(player_provider_mapping_id, provider_season_mapping_id, retrieved_at desc)`
    - replay uses `on conflict ... do update` to advance retrieval/freshness timestamps for identical content instead of duplicating rows

14. `player_enrichment_attempts`
    - `id`, unique non-empty `request_key`
    - nullable workflow run, required canonical player and provider references
    - state: `pending`, `running`, `succeeded`, `stale_used`, `unresolved`, `ambiguous`, `unsupported_competition`, `rate_limited`, `provider_unavailable`, `schema_changed`, `deadline_exceeded`, or `failed`
    - `attempt_count`, started/finished/retry timestamps, nullable error code/message, JSON evidence
    - `unique (workflow_run_id, player_id, provider_id)` when workflow run is present
    - indexes `(state, retry_after)` and `(player_id, created_at desc)`
    - n8n upserts by request key, so a restart updates one logical attempt

Foreign keys use `on delete restrict` for provider mappings, seasons, profiles, and snapshots whose provenance must remain valid. Alias rows may cascade with their provider-neutral parent. The migration must test each delete behavior explicitly.

### Provenance and retention

- Keep confirmed player/club/competition mappings indefinitely.
- Keep the normalized current profile indefinitely while its player exists; retain only the latest raw profile.
- Keep normalized snapshots for the current and previous domestic seasons.
- Keep raw statistic payloads for those retained seasons; purge older raw JSON before deleting older snapshot rows.
- Keep normal successful attempts for 90 days.
- Keep ambiguous/manual-resolution evidence for 365 days.
- Run retention from a later n8n maintenance node or documented SQL after rollout; do not add an unrequested database scheduler in migration `002`.

### Rollback

The operational rollback is application-first:

1. disable enrichment output/configuration;
2. redeploy the previous n8n/service Compose version;
3. leave migration `002` tables inert.

This preserves applied-migration history and makes rollback data-safe. A full DDL reversal is destructive and should only be performed on a disposable test database or by restoring a pre-migration backup after explicit approval. Do not create an automatic production down migration.

## 7. Service/API contract

### Runtime

- Python `3.12` on `python:3.12-slim`, matching the existing compatible service baseline.
- Exact `soccerdata==1.9.1` and a fully hash-locked dependency file generated from a human-readable input.
- Standard-library HTTP server unless implementation evidence shows an existing dependency is materially simpler; do not add FastAPI only for two endpoints.
- One supervisor process and one replaceable provider worker process.
- Graceful shutdown: stop accepting requests, allow the current batch up to the configured grace period, then terminate the worker.

### Endpoints

#### `GET /health`

Liveness only. Returns `200` when the supervisor loop is running. It must not call Sofascore.

```json
{"status":"ok","service":"sofascore-enrichment"}
```

#### `GET /ready`

Returns `200` only when the package version is correct, the cache directory is writable, and a provider worker can be started. It must not call Sofascore.

```json
{
  "status": "ready",
  "soccerdata_version": "1.9.1",
  "cache_writable": true,
  "worker_ready": true
}
```

#### `POST /v1/enrich`

Example request:

```json
{
  "request_id": "workflow-run:1842",
  "deadline_ms": 45000,
  "players": [
    {
      "canonical_player_id": "42",
      "name": "Kylian Mbappé",
      "current_club": "Real Madrid",
      "identity_hint": {
        "nationality": "France",
        "position": "forward"
      },
      "confirmed_provider_player_id": "826643",
      "confirmed_competition": {
        "provider_competition_id": "8",
        "provider_season_id": "77559"
      }
    }
  ]
}
```

`confirmed_*` values are optional and are sent only from locked or confirmed database mappings.

Example successful partial-capable response:

```json
{
  "request_id": "workflow-run:1842",
  "soccerdata_version": "1.9.1",
  "retrieved_at": "2026-07-30T00:30:00Z",
  "results": [
    {
      "canonical_player_id": "42",
      "status": "resolved",
      "match": {
        "provider": "sofascore",
        "player_id": "826643",
        "confidence": 1.0,
        "evidence": ["confirmed_provider_player_id"]
      },
      "profile": {
        "canonical_name": "Kylian Mbappé",
        "current_club": {"provider_id": "2829", "name": "Real Madrid"},
        "nationality": {"code": "FRA", "name": "France"},
        "date_of_birth": "1998-12-20",
        "age": 27,
        "primary_position": "F",
        "height_cm": 180,
        "preferred_foot": "right",
        "market_value": 191000000,
        "market_value_currency": "EUR",
        "source_id": "sofascore:826643",
        "source_url": "https://www.sofascore.com/football/player/kylian-mbappe/826643"
      },
      "competition": {
        "provider_competition_id": "8",
        "name": "LaLiga",
        "provider_season_id": "77559",
        "season": "2025/26",
        "scope": "selected_league_all_clubs"
      },
      "statistics": {
        "appearances": 31,
        "starts": 29,
        "minutes_played": 2604,
        "minutes_per_game": 84.0,
        "goals": 25,
        "expected_goals": 23.9453,
        "assists": 5,
        "expected_assists": 6.2019957,
        "average_rating": 7.5612903225806
      },
      "provenance": {
        "cache": "miss",
        "schema_version": 1,
        "endpoint_kinds": ["player", "statistics"],
        "content_hashes": {
          "profile": "<sha256>",
          "statistics": "<sha256>"
        },
        "raw_payloads": {
          "profile": {"...": "validated provider JSON"},
          "statistics": {"...": "validated provider JSON"}
        }
      }
    }
  ]
}
```

Valid batches return HTTP `200` even when individual statuses are:

- `partial`
- `unresolved`
- `ambiguous`
- `unsupported_competition`
- `provider_unavailable`
- `rate_limited`
- `schema_changed`
- `deadline_exceeded`

Top-level protocol errors:

- `400`: malformed JSON or invalid contract;
- `413`: more than 25 players or request body above the fixed size;
- `503`: supervisor is not ready.

```json
{
  "request_id": "workflow-run:1842",
  "error": {
    "code": "invalid_request",
    "message": "players must be a non-empty array with at most 25 entries",
    "retryable": false
  }
}
```

Do not expose raw upstream response bodies in HTTP error messages. `raw_payloads` contains only the resolved player's validated profile/statistics/competition-season objects, not all search candidates. It is consumed by the persistence node on the private network and is never copied into Discord or logs. Logs are restricted to IDs, endpoint kinds, sizes, and hashes.

### Configuration

Tracked Compose uses safe defaults; secrets are unnecessary.

| Variable | Default | Purpose |
| --- | --- | --- |
| `SOCCERDATA_DIR` | `/var/lib/soccerdata` | Persistent package data/cache root |
| `SOFASCORE_SERVICE_PORT` | `8080` | Internal listen port |
| `SOFASCORE_MIN_REQUEST_INTERVAL_SECONDS` | `1.0` | Provider rate gate |
| `SOFASCORE_BATCH_LIMIT` | `25` | Bounded input |
| `SOFASCORE_BATCH_DEADLINE_SECONDS` | `45` | Worker hard deadline |
| `SOFASCORE_PROFILE_CACHE_HOURS` | `168` | Raw profile cache age |
| `SOFASCORE_STATS_CACHE_HOURS` | `12` | Raw current stats cache age |
| `SOFASCORE_MAPPING_CACHE_HOURS` | `168` | Tournament/season cache age |
| `SOFASCORE_CIRCUIT_FAILURE_THRESHOLD` | `3` | Open circuit after repeated provider failures |
| `SOFASCORE_CIRCUIT_COOLDOWN_SECONDS` | `300` | Cooldown before a probe |
| `LOG_LEVEL` | `INFO` | Structured log level |

The n8n-side URL is `SOFASCORE_ENRICHMENT_URL=http://sofascore-enrichment:8080`. It is not a secret and must not include a public hostname.

### Schema-change detection

Each endpoint normalizer has:

- a fixture-backed expected-shape contract;
- required structural keys for entity identity;
- nullable value keys for optional fields;
- explicit numeric/type/range validation;
- a local schema version and canonical content hash.

Unknown extra fields are retained in raw JSON and do not fail normalization. A missing or invalid identity/structural key produces `schema_changed`, retains the last-good database row, opens/advances the circuit, and emits a structured log. Optional field loss produces `partial`, not failure.

## 8. Workflow integration

Modify the generator only; regenerate `workflow/football-transfer-monitor.json` from it.

Insert this fail-open sequence after `Set preferred report source` and before the existing digest-candidate path:

1. **Prepare distinct enrichment candidates** — collect persisted canonical player IDs, report names, current-club evidence, and identity hints; deduplicate by player ID.
2. **Load cached enrichment state** — one PostgreSQL query loads confirmed/manual mappings, fresh snapshots, permitted stale snapshots, and only candidates needing refresh. It always emits one aggregate item, even for an empty candidate set.
3. **Build Sofascore enrichment request** — omit fresh candidates and cap the refresh list at 25. Preserve a passthrough digest context.
4. **Enrich players via Sofascore** — call `POST /v1/enrich`, no node retry, 60-second timeout, and regular error output/`continueOnFail`.
5. **Normalize enrichment outcome** — combine service successes with fresh cache and permitted stale fallback. Convert service/node errors into per-player attempt states. Always emit one item.
6. **Persist enrichment results** — bulk JSONB PostgreSQL upsert for mappings/profiles/snapshots/attempts. Configure the node to continue when the enrichment-only write fails.
7. **Continue after enrichment** — unconditional code node that restores the digest context regardless of call or persistence outcome.
8. **Prepare digest candidates** — retain the current selection/revision rules and left join the latest usable profile/statistics for presentation only.

The exact generator areas are:

- node construction near `workflow/build-workflows.mjs:677-706`;
- connection construction near `workflow/build-workflows.mjs:754-760`;
- candidate SQL near `workflow/build-workflows.mjs:219-271`;
- shared story construction in `workflow/lib.mjs:418-492`.

Required semantics:

- per-run deduplication is by canonical `player_id`;
- cross-run deduplication uses confirmed provider mappings, TTL checks, snapshot hashes, and unique request keys;
- an empty batch skips the HTTP call;
- service errors, malformed responses, and database enrichment errors all continue to the existing digest query;
- the digest candidate query uses `left join lateral` or equivalent and never filters out a transfer because enrichment is absent;
- transfer report snapshot generation and `content_sha256` remain byte-for-byte independent of enrichment;
- refreshed statistics alone create no `transfer_report_revision`, digest candidate, or delivery;
- a later material transfer revision may display the freshest available player snapshot;
- existing report merge, preferred-source, revision, reservation, and delivery idempotency remain unchanged.

## 9. Discord presentation

Illustrative compact field:

```text
Kylian Mbappé — Rumour
Real Madrid → Liverpool • €150m reported
Profile: France • 27 • FW • 180 cm • right • €191m proposed
LaLiga 2025/26: 31 apps (29 starts) • 2,604 min (84/game) • 25 G • 5 A • 23.95 xG • 6.20 xA • 7.56
Source: @journalist
```

The transfer line above is illustrative; the profile/statistics values are from the feasibility spike.

Rules:

- preserve the transfer classification, club movement, fee/status, and journalist link as primary content;
- omit every null field rather than showing `unknown`, `0`, or a placeholder;
- label the provider value as `proposed`;
- format a currency symbol only for a known code; otherwise use `191,000,000 EUR`;
- always include competition and season when statistics are shown;
- do not add a second field or embed for enrichment;
- recalculate the existing 1,024-character field and 6,000-character aggregate budgets after optional lines are added.

When space is limited, retain content in this order:

1. player/transfer identity and journalist source link;
2. transfer classification, clubs, fee, and status;
3. competition/season, appearances, minutes, goals, and assists;
4. position, age, nationality, and proposed market value;
5. starts, xG, xA, rating, height, preferred foot, and extra statistics.

Truncation removes whole optional tokens from the bottom of that order; it must never cut a URL, currency number, or Unicode sequence. Existing story count, 25-field, field-name, field-value, and aggregate embed limits remain authoritative.

## 10. File-by-file implementation plan

No active file is deleted. Historical Transfermarkt artifacts remain deleted and migration `001` remains untouched.

| Path | Action | Responsibility / important interfaces | Tests affected |
| --- | --- | --- | --- |
| `deploy/n8n/sofascore/app.py` | Create | Standard-library HTTP supervisor, `/health`, `/ready`, `/v1/enrich`, request limits, worker lifecycle, structured errors/logs | New service contract tests |
| `deploy/n8n/sofascore/adapter.py` | Create | Thin `soccerdata.Sofascore.get()` adapter, endpoint/cache paths, normalization, identity scoring, league/season selection, deadline-safe worker entrypoint | New adapter/fixture tests |
| `deploy/n8n/sofascore/Dockerfile` | Create | Python 3.12-slim image, non-root user, hash-locked install, healthcheck command, no browser binary | Docker build/smoke |
| `deploy/n8n/sofascore/requirements.in` | Create | Human-readable exact top-level `soccerdata==1.9.1` pin | Lock verification |
| `deploy/n8n/sofascore/requirements.txt` | Create | Fully resolved, hash-locked dependency tree | Reproducible Docker build |
| `deploy/n8n/sofascore/tests/fixtures/mbappe_search.json` | Create | Recorded search fixture | Identity success |
| `deploy/n8n/sofascore/tests/fixtures/mbappe_profile.json` | Create | Recorded profile fixture | Full profile normalization |
| `deploy/n8n/sofascore/tests/fixtures/laliga_seasons.json` | Create | Recorded season fixture | Active-season selection |
| `deploy/n8n/sofascore/tests/fixtures/mbappe_laliga_stats.json` | Create | Recorded rich stats fixture | Full stats normalization |
| `deploy/n8n/sofascore/tests/fixtures/john_smith_search.json` | Create | Duplicate/mixed-sport fixture | Ambiguity rejection |
| `deploy/n8n/sofascore/tests/fixtures/quang_hai_profile.json` | Create | Non-top-five profile and conflicting tournament evidence | Primary-tournament rule |
| `deploy/n8n/sofascore/tests/fixtures/vleague_seasons.json` | Create | Non-top-five season fixture | Generic season resolution |
| `deploy/n8n/sofascore/tests/fixtures/quang_hai_vleague_stats.json` | Create | Sparse stats fixture | Nullable xG/xA |
| `deploy/n8n/sofascore/tests/fixtures/schema_changed.json` | Create | Malformed structural response | Last-good/schema guard |
| `deploy/n8n/sofascore/tests/test_adapter.py` | Create | Normalization, matching, cache-path, league/season, request-budget, and failure tests | New Python unit suite |
| `deploy/n8n/sofascore/tests/test_app.py` | Create | HTTP validation, partial results, health/readiness, deadline, shutdown, and log-redaction tests | New Python contract suite |
| `deploy/n8n/sofascore/tests/test_live.py` | Create | Explicitly gated Mbappé/duplicate/non-top-five acceptance probe | Never normal CI |
| `deploy/n8n/compose.yaml` | Modify | Add private `sofascore-enrichment` service using image `transfers-n8n-sofascore:local`, health dependency, n8n internal URL, and named cache volume; no host port | Compose config and smoke |
| `deploy/n8n/README.md` | Modify | Service operations, config, cache, health, troubleshooting, manual circuit/rollback procedure | Documentation check |
| `database/migrations/002_soccerdata_sofascore_enrichment.sql` | Create | Tables, constraints, indexes, provider seed, timestamps | New SQL tests |
| `database/migrate.sql` | Modify | Register migration `002` after `001` under existing advisory lock | Migration replay test |
| `database/tests/003_soccerdata_sofascore_enrichment.sql` | Create | Transactional constraints, mapping replay, snapshot hashes, attempts, delete behavior | SQL test runner |
| `database/README.md` | Modify | Schema purpose, TTL/retention SQL, manual mapping SQL, forward-only rollback | Documentation check |
| `workflow/build-workflows.mjs` | Modify | Generated fail-open nodes/connections, cache/upsert SQL, optional enrichment join | Generator/unit/E2E |
| `workflow/lib.mjs` | Modify | Nullable enrichment normalization for Discord and whole-token priority truncation | Workflow library tests |
| `workflow/football-transfer-monitor.json` | Regenerate | Generated output only; never edit manually | `--check` |
| `workflow/README.md` | Modify | Node flow, failure behavior, stats revision semantics | Documentation check |
| `tests/unit/workflow-lib.test.mjs` | Modify | Enrichment formatting, null omission, limits, stale/failure behavior, unchanged report hash | Node unit tests |
| `tests/e2e/compose.yaml` | Modify | Include mock enrichment endpoint/service networking without public exposure | E2E |
| `tests/e2e/mock/server.mjs` | Modify | Fixture-backed success, ambiguity, sparse, 429, malformed, and timeout responses | E2E |
| `tests/e2e/scenario.mjs` | Modify | Verify enrichment display and all-failure digest delivery/idempotency | E2E |
| `tests/e2e/run.sh` | Modify | Run migration `003` and service/Compose smoke in existing sequence | Full E2E |
| `tests/README.md` | Modify | Fixture/live flags and commands | Documentation check |
| `README.md` | Modify | Replace historical concept with supported Sofascore enrichment and fail-open behavior | Documentation check |

Do not modify:

- `database/migrations/001_initial_schema.sql`;
- Qwen prompt or response schema;
- report merge/material hash rules except tests proving they remain independent;
- current X collection providers;
- public network/port configuration;
- `graphify-out`;
- any unrelated formatting or dead code.

## 11. Ordered milestones

### Milestone 1 — Fixture-backed adapter and service contract

Changes:

- create only `deploy/n8n/sofascore/`;
- pin/hash-lock soccerdata 1.9.1;
- implement targeted adapter, normalized nullable contract, player matching, league/season selection, health/readiness, worker deadline, fixtures, and unit/contract tests;
- no Compose, database, workflow, or Discord changes.

Dependencies: none beyond Python/Docker and the verified package release.

Verification:

```bash
docker build -t transfers-sofascore:test deploy/n8n/sofascore
docker run --rm --read-only --tmpfs /tmp \
  -v sofascore-test-cache:/var/lib/soccerdata \
  transfers-sofascore:test python -m unittest discover -s tests -p 'test_*.py'
docker volume rm sofascore-test-cache
```

Acceptance:

- Mbappé normalizes all observed profile/stat fields;
- John Smith is not automatically matched;
- Nguyễn Quang Hải resolves V-League 1 through `primaryUniqueTournament` and retains null xG/xA;
- malformed structural fixtures produce `schema_changed`;
- optional fields remain null, not invented;
- a simulated hung call returns by the deadline and the next request gets a fresh worker;
- tests prove the service invokes only `soccerdata.Sofascore` and no browser runtime.

Rollback point: delete the newly created `deploy/n8n/sofascore/` directory before it is referenced anywhere.

### Milestone 2 — Restart-safe database model

Changes:

- add/register migration `002`;
- add SQL test `003`;
- document mappings, manual override SQL, freshness, retention, and application-first rollback.

Dependencies: Milestone 1 contract and normalized field names are frozen.

Verification:

```bash
docker compose -f tests/e2e/compose.yaml up -d --wait postgres
docker compose -f tests/e2e/compose.yaml exec -T postgres \
  psql -U transfers_e2e -d transfers_e2e -v ON_ERROR_STOP=1 -f /database/migrate.sql
docker compose -f tests/e2e/compose.yaml exec -T postgres \
  psql -U transfers_e2e -d transfers_e2e -v ON_ERROR_STOP=1 -f /database/migrate.sql
for test_file in /database/tests/001_dedup_restart_safety.sql \
  /database/tests/002_workflow_safety.sql \
  /database/tests/003_soccerdata_sofascore_enrichment.sql; do
  docker compose -f tests/e2e/compose.yaml exec -T postgres \
    psql -U transfers_e2e -d transfers_e2e -v ON_ERROR_STOP=1 -f "$test_file"
done
docker compose -f tests/e2e/compose.yaml down --volumes --remove-orphans
```

Acceptance:

- both migration runs succeed with one recorded `002`;
- duplicate provider IDs, manual mappings, logical attempts, and same-content snapshots cannot duplicate;
- promoted/relegated club mappings coexist by season;
- every rollback-based SQL test returns the database to its pre-test state;
- migration `001` is unchanged.

Rollback point: before production application, discard migration `002`; after application, deploy without feature use and leave its tables inert.

### Milestone 3 — Private deployment and service smoke

Changes:

- add the service, n8n URL, health dependency, resource limits, and persistent cache volume to `deploy/n8n/compose.yaml`;
- update deployment documentation.

Dependencies: Milestones 1 and 2.

Verification:

```bash
export N8N_RUNNERS_AUTH_TOKEN=test X_COLLECTOR=twscrape
export DISCORD_TRANSFERS_WEBHOOK_URL=http://invalid
export DISCORD_ERRORS_WEBHOOK_URL=http://invalid
export TWSCRAPE_AUTH_TOKEN=test TWSCRAPE_CT0=test
export POSTGRES_USER=test POSTGRES_PASSWORD=test
docker compose -f deploy/n8n/compose.yaml config --quiet
docker compose -f deploy/support/compose.yaml config --quiet
docker compose -f deploy/n8n/compose.yaml build sofascore-enrichment
docker run -d --name transfers-sofascore-smoke \
  --read-only --tmpfs /tmp -v sofascore-smoke-cache:/var/lib/soccerdata \
  transfers-n8n-sofascore:local
docker exec transfers-sofascore-smoke python -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/ready', timeout=2).read().decode())"
docker inspect transfers-sofascore-smoke \
  --format 'user={{.Config.User}} ports={{json .HostConfig.PortBindings}}'
docker rm -f transfers-sofascore-smoke
docker volume rm sofascore-smoke-cache
```

Acceptance:

- readiness succeeds from the private network;
- no host port is published;
- the container runs non-root, starts without secrets or browser binaries, and reuses the named cache after restart;
- idle target is approximately 0.5 CPU or less, 512 MiB memory, and a 1 GiB monitored cache-volume budget.

Rollback point: remove the service stanza, n8n URL, and named volume reference; preserve the volume until explicit deletion approval.

### Milestone 4 — Fail-open workflow persistence

Changes:

- add generator nodes/connections for distinct lookup, cache load, service call, outcome normalization, conflict-safe persistence, and unconditional continuation;
- left join optional enrichment into digest candidates;
- regenerate workflow JSON.

Dependencies: Milestones 1–3.

Verification:

```bash
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
node --test tests/unit/*.test.mjs
```

Acceptance:

- one service request contains each canonical player at most once;
- fresh cache skips the HTTP call;
- replay upserts one logical enrichment attempt/snapshot;
- service 429, 503, timeout, invalid JSON, and enrichment-database failure all reach the existing digest candidate and delivery path;
- transfer report hashes and revision counts are unchanged by statistics refresh;
- generated JSON matches the generator.

Rollback point: revert only the generator/regenerated JSON changes; service and tables remain inert.

### Milestone 5 — Bounded Discord presentation

Changes:

- add optional profile/stat lines in `workflow/lib.mjs`;
- add null, currency, Unicode, field, aggregate, and priority tests.

Dependencies: Milestone 4 supplies optional normalized rows.

Verification:

```bash
node --test tests/unit/workflow-lib.test.mjs
node workflow/build-workflows.mjs --check
```

Acceptance:

- primary transfer and journalist content is never displaced by enrichment;
- null values are omitted;
- competition/season and proposed-value labeling are present when relevant;
- every field stays within 256/1,024 characters, at most 25 fields are emitted, and aggregate embed text remains at most 6,000 characters;
- all-enrichment-failed output equals the current transfer-only layout.

Rollback point: revert only the library/generator presentation change; collection and persistence may remain enabled in shadow mode.

### Milestone 6 — End-to-end shadow rollout and activation

Changes:

- add fixture-backed E2E cases and operational instructions;
- deploy with persistence enabled but Discord rendering disabled;
- enable test Discord, then production rendering only after activation criteria pass.

Dependencies: Milestones 1–5 and an approved deployment window.

Verification:

```bash
./tests/e2e/run.sh
docker run --rm -e SOFASCORE_LIVE_TEST=1 \
  -v sofascore-live-cache:/var/lib/soccerdata \
  transfers-n8n-sofascore:local \
  python -m unittest discover -s tests -p 'test_live.py'
docker volume rm sofascore-live-cache
docker compose -f deploy/n8n/compose.yaml logs --since=24h sofascore-enrichment
```

Acceptance:

- normal CI and E2E use recorded fixtures only;
- the gated live test resolves the three spike cases without unsafe matching;
- shadow runs complete for at least 48 hours with zero digest blocks, acceptable cache hit rate, no sustained circuit opening, and reviewed ambiguous mappings;
- test Discord passes limit/link review;
- disabling the rendering/config flag returns transfer-only output without a migration rollback.

Rollback point: disable enrichment rendering first, then service calls; redeploy the previous workflow/Compose version while leaving database objects and cache volume intact.

## 12. Test strategy

### Python unit and fixture tests

- Record sanitized JSON fixtures with endpoint kind, retrieval date, and package version; do not include cookies or headers.
- Cover Mbappé rich data, John Smith ambiguity, Nguyễn Quang Hải sparse data, missing team/DOB/value/foot/height/starts/xG/xA/rating, unexpected extra fields, wrong types, and missing identity keys.
- Mock `Sofascore.get()`; assert endpoint/cache paths and the maximum request budget.
- Cover accents, punctuation, transliterations, club aliases, score threshold, runner-up margin, manual lock, and changed club evidence.
- Cover `primaryUniqueTournament` versus `team.tournament`, top-five and non-top-five mappings, promoted/relegated season scoping, cross-league moves, cups, continental, international, youth, reserve, and women's exclusions.
- Cover rate gate, circuit breaker, stale cache, worker deadline/restart, partial result, and log redaction.

### SQL tests

- Run inside `begin`/`rollback`, following existing tests.
- Verify every unique/check/foreign-key constraint and each partial index with positive and negative cases.
- Replay the same workflow request, mapping, profile, and snapshot.
- Verify content-hash upsert advances freshness without duplicate rows.
- Verify one provider external ID cannot map to two canonical players.
- Verify manual locks survive automatic conflicts and old-season mappings cannot resolve a new season.
- Verify application rollback needs no table deletion.

### Service contract tests

- Test valid batch, empty/oversized/malformed body, individual partial errors, top-level readiness error, and stable JSON types.
- Test `200` for mixed results and `400/413/503` only for protocol/service failures.
- Test process shutdown and replacement after a hung provider call.
- Test no raw provider payload or report text leaks into error logs.

### Workflow-generation tests

- Verify exact node names, order, failure edges, timeouts, and unconditional continuation.
- Verify empty-candidate flow avoids the service.
- Verify statistics refresh does not affect merge snapshot/hash/revision selection.
- Verify cache/stale rows are left joined and never filter digest candidates.
- Run generator `--check`; never patch generated JSON manually.

### Discord tests

- Assert null omission, decimal rounding, ISO currency handling, stale metadata behavior, and Unicode-safe whole-token truncation.
- Test field-name 256, field-value 1,024, 25 fields, and 6,000 aggregate characters at boundaries.
- Assert the journalist link and core transfer text remain when all optional data is removed.

### Docker and E2E tests

- Build from a clean cache with hash checking.
- Assert no published port, non-root user, health/readiness, cache persistence across restart, and graceful shutdown.
- Mock success, ambiguity, sparse response, 429, malformed schema, timeout, and total service outage.
- Assert total enrichment outage still reserves, sends, and finalizes the transfer digest exactly once.

### Gated live test

- Disabled unless `SOFASCORE_LIVE_TEST=1`.
- Run sequentially with the production rate gate.
- Check only durable identity and structural invariants; tolerate nullable metrics.
- Never run in normal CI.
- A live failure blocks activation, not transfer-only tests or digest delivery.

## 13. Operations and rollout

### Deployment

- Build the hash-locked Python 3.12 image.
- Join only `transfers_net`; publish no host port.
- Mount the named soccerdata cache at `/var/lib/soccerdata`.
- Give only the n8n container the internal URL.
- Do not add credentials; Sofascore access in the verified design is unauthenticated.
- Back up PostgreSQL before applying migration `002`.
- Apply migrations under the existing advisory lock, then start the service and check readiness from n8n.

### Observability

Emit one-line structured JSON logs with:

- request ID and workflow run ID;
- canonical/provider player IDs when resolved;
- endpoint kind, cache hit/miss/stale, duration, attempt result, and schema version;
- circuit state and worker replacement;
- counts for resolved, partial, ambiguous, unresolved, stale-used, and failed players.

Never log cookies, full raw payloads, report bodies, or Discord webhook URLs.

Monitor:

- service readiness and restarts;
- batch latency and deadline rate;
- provider call count and cache-hit ratio;
- 403/429/5xx/generic connection failures;
- schema-change/partial-field rates;
- ambiguous/unresolved rate;
- age of last-good profiles/statistics;
- enrichment database failures;
- digest completion rate, which must remain unchanged.

### Rollout sequence

1. Run fixture-backed unit, SQL, contract, workflow, Discord, and Docker tests locally.
2. Run the explicit live read-only acceptance probe.
3. Deploy in shadow mode: resolve/persist/log but do not alter Discord.
4. Observe at least 48 hours/two days of six-hour runs and review ambiguous mappings, request volume, cache hits, stale use, and digest completion.
5. Enable enrichment in a test Discord destination and inspect limits, currency labels, links, and null omission.
6. Enable production rendering only after the activation criteria below pass.

Activation criteria:

- no unsafe duplicate-name resolution in fixture/live cases;
- no cup/international/youth/reserve/women selection;
- no schema-change failures in the current live fixtures;
- service p95 batch time under the n8n timeout;
- no digest failure caused by enrichment;
- confirmed restart-safe database replay;
- acceptable provider call volume with no sustained rate limiting;
- test Discord stays inside all limits.

### Failure handling

| Failure | Behavior |
| --- | --- |
| Sofascore unavailable / 403 / 5xx | Open/advance circuit, return per-player error, use permitted stale row, continue digest |
| Rate limiting / 429 | Record retry time when available, no same-run outer retry, use stale row, continue digest |
| Malformed/changed response | `schema_changed`, retain raw hash/evidence and last-good normalized row, continue digest |
| Unsupported competition | Persist pending mapping/attempt, omit stats, continue with profile/transfer |
| Unresolved player | Persist attempt only, omit enrichment |
| Ambiguous player | Persist candidate evidence, require manual override, never fuzzy-select |
| Stale cache | Use only within stated stale windows and record `stale_used`; otherwise omit |
| Partial fields | Persist valid values, keep absent values null, omit null Discord tokens |
| Service timeout | n8n continues; supervisor terminates/replaces worker |
| Enrichment database interruption | Continue with in-memory/fresh transfer context; do not block digest |
| soccerdata regression | Pin/rollback image version, open circuit, preserve last-good snapshots, keep transfer-only delivery |

### Rollback

1. Disable Discord enrichment rendering.
2. Disable n8n service calls if necessary.
3. Redeploy the last known-good workflow and Compose definitions.
4. Keep migration `002` tables and cache volume until recovery is understood.
5. Roll back the service image pin independently.

No rollback step rewrites historical migrations, deletes provider data automatically, or changes current transfer revisions/deliveries.

## 14. Risks and unresolved questions

### Blockers before production activation

1. **High — undocumented player endpoint/schema stability.** Player enrichment is not supported by soccerdata's high-level Sofascore methods. Activation requires the fixture contract, live gated test, schema guard, and successful shadow window.
2. **High — request/error behavior.** The inherited reader has generic retries and no explicit timeout argument. Activation requires hard worker-process deadline tests and conservative rate/circuit settings.
3. **High — incomplete competition metadata outside common leagues.** A league without enough provider evidence must remain `unsupported_competition` until a stored manual mapping is reviewed.
4. **High — provider-access policy/availability.** Direct curl returned 403 and there is no provider SLA. Operations must confirm the intended read-only use remains acceptable before production activation; there is deliberately no automatic provider fallback.

### Non-blocking risks

1. **Medium — nullable coverage.** Sparse leagues may lack starts, xG, xA, rating, height, foot, or proposed value. The data model and Discord output already preserve nullability.
2. **Medium — large transitive dependency tree.** soccerdata's package dependencies include SeleniumBase even though this service uses no browser. Hash-locking and image scanning are required; replacing or partially installing the package is out of scope.
3. **Medium — stale current-club evidence.** A provider profile may lag a transfer report. Club-backed matching uses report evidence, does not overwrite manual locks, and refreshes season mappings.
4. **Low — source URL format drift.** The stable provider/player ID remains authoritative if the convenience URL changes.
5. **Low — extra-stat display value.** Shots/key-pass fields are cheap to retain but optional to display. They should remain behind the existing content-priority budget.

No user decision blocks Milestone 1. TTLs, resource limits, and confidence thresholds are explicit starting values and may be tuned only from shadow evidence without changing safety rules.

## 15. Implementation handoff

Use this exact next Codex prompt:

```text
Implement Milestone 1 only from docs/plans/sfc_scrape_plan.md on branch
feature/sfc_scrape.

Scope:
- Create only deploy/n8n/sofascore/ and the files assigned to Milestone 1.
- Use Python 3.12 and hash-lock soccerdata==1.9.1 with its supported dependency tree.
- Import and use soccerdata.Sofascore only.
- Implement the thin targeted JSON adapter through inherited Sofascore.get(),
  normalized nullable schemas, deterministic identity/league/season rules,
  stdlib HTTP endpoints, one replaceable provider worker, deadline/rate/circuit
  behavior, recorded fixtures, and unit/contract tests.
- Use the Mbappé, John Smith, and Nguyễn Quang Hải cases defined in the plan.

Do not:
- modify Compose, database, workflow, Discord, README, deployment, migration,
  or generated workflow files;
- add Playwright, Selenium usage/browser binaries, ScraperFC, another Sofascore
  package, another football provider, rendered-HTML scraping, or live CI;
- auto-match John Smith or invent absent fields.

Before editing, restate Milestone 1 assumptions and the file-level checklist.
Then implement the smallest code matching the plan. Run:

docker build -t transfers-sofascore:test deploy/n8n/sofascore
docker run --rm --read-only --tmpfs /tmp \
  -v sofascore-test-cache:/var/lib/soccerdata \
  transfers-sofascore:test python -m unittest discover -s tests -p 'test_*.py'
docker volume rm sofascore-test-cache

Stop when Milestone 1 acceptance criteria pass. Report changed files, exact test
results, remaining package/API risks, and git status. Do not start Milestone 2,
commit, push, or open a pull request unless explicitly asked.
```
