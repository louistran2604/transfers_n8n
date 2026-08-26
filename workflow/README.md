# Workflow generation and import

`build-workflows.mjs` is dependency-free and is the only source for the generated workflow JSON files. It parses `docs/journalist_list.md` directly, validates every account ID as a decimal string, and rejects a registry that does not contain exactly 78 accounts. It never reads collector sample requests for IDs.

```bash
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
```

Generated files:

- `football-transfer-monitor.json`: scheduled/manual collection, Qwen extraction, PostgreSQL merge, optional Sofascore enrichment, digest reservation, and Discord delivery.
- `football-transfer-monitor-errors.json`: n8n error trigger, PostgreSQL failure record, and error webhook.

Both workflows target n8n `2.31.6`, use `Asia/Ho_Chi_Minh`, and contain no secret values. They reference the intentionally missing PostgreSQL credential named `Transfers PostgreSQL`; map it after import in n8n.

## Extraction contract

`qwen-system-prompt.md` and `qwen-response-schema.json` are embedded verbatim into the generated workflow. The model may output only `transfer_related` and normalized report terms. Journalist/source identity, URL, platform, timestamp, priority, and reliability are injected from the normalized selected-collector post and generated source registry after model output, so Qwen cannot invent them.

`PROBABILITY_MODE=shadow` stores the validated `qwen-evidence-v1` evidence and deterministic PostgreSQL `probability-v1` raw revision for each destination. Missing, invalid, or `active` values are treated as `off`; shadow probabilities do not change Discord output. Destination/stay normalization is not part of this stage, so `normalized_probability` temporarily equals `raw_probability`.

## X collector selection

`X_COLLECTOR` must be explicitly `twscrape` or `rapidapi`. The generated `twscrape` branch submits all configured numeric X IDs as strings in one request, then adapts successful normalized posts into the existing raw-post SQL parameters. Its structured source failures produce no raw-post rows and do not stop successful sources. The retained RapidAPI branch keeps its existing per-source request and retry behavior. Both branches join before `Persist raw posts`; Qwen, PostgreSQL deduplication, report merging, digest reservation, and Discord delivery are unchanged.

Classification conflict precedence is: contract renewal, rejected/failed, loan, official/confirmed, advanced negotiations, then rumor. Fees and clauses are base-unit amounts, currencies are ISO codes, all report properties are required, and unknown nullable data is `null`.

## Optional Sofascore enrichment

`PLAYER_ENRICHMENT_MODE` accepts `off`, `shadow`, or `active`; a missing or invalid value is treated as `off`. The default `off` path goes directly from the preferred-source update to digest candidate loading and makes no enrichment context query or HTTP request. `shadow` resolves, fetches, and persists normalized enrichment without attaching it to digest candidates. `active` also left-joins and renders eligible fresh snapshots, or failure-gated stale snapshots within the documented windows.

The generated optional branch is:

```text
Update preferred sources
  → Check player enrichment mode
  → off: Prepare digest candidates query
  → shadow/active: Load contexts → Build request → Enrich → Validate → Persist
  → Prepare digest candidates query
```

The private request uses `SOFASCORE_ENRICHMENT_BASE_URL` (default `http://sofascore-enrichment:8080`), an 85-second n8n timeout, full responses, no HTTP retry, and at most 25 grouped items. Grouping uses a confirmed provider player ID or a Unicode reported-name plus verified club context, never the placeholder `players.id`. Context, service, contract, and enrichment-persistence failures rejoin `Prepare digest candidates query`; core PostgreSQL failure remains fatal because safe reservation depends on it.

Enrichment persistence is transactional and replay-safe. Canonical provider identity is kept on later report merges, while profile/statistics refreshes never enter the transfer snapshot hash, create a transfer revision, make a delivered revision eligible again, or trigger a resend. Discord reservation stores the exact request body in `digest_deliveries.request_payload`; conflict recovery returns and sends that stored body rather than rebuilding it.

Only `active` renders enrichment. Fresh profile data may render without statistics. Statistics render only with the persisted competition, season, and exact `selected_domestic_league_all_clubs` scope. Failure-gated stale statistics and attached-player profiles are limited to 72 hours from provider retrieval; an explicitly unattached profile is limited to 7 days. Stale data is labeled, null fields disappear, and unresolved, ambiguous, invalid, or failed items add no Discord line.

Discord construction first admits the existing transfer stories and source links, then appends only complete enrichment groups that fit. Enrichment cannot displace a story or truncate the final journalist link, a currency token, or a Unicode grapheme. Total enrichment failure therefore produces the same transfer-only digest when core PostgreSQL is healthy.

Keep the mode `off` during build, migration, import, and local verification. Provider-policy approval, the complete offline suite, the separately gated live acceptance, resource measurement, and the documented shadow review are activation blockers.

## Retry and delivery rules

RapidAPI permits at most five attempts and Qwen at most three. The `twscrape` HTTP request has a finite 310-second timeout. The shared logic calculates bounded exponential delay and respects `Retry-After` or rate-reset headers. Discord is retryable only for an explicit `429` or `5xx`; a request interrupted after the network write is marked `unknown` and is never automatically resent.

The digest ranks confirmed transfers first, then Fabrizio Romano or David Ornstein reports, Qwen-marked huge rumors between major clubs, reported €70m/£70m rumors, and all other transfer news. It has at most 15 normal stories; positions 16–18 are only confirmed transfers or Romano/Ornstein reports. It also caps output at 10 embeds, 25 fields per embed, 1,024 characters per field, and 6,000 aggregate embed characters.

`womens-football-blacklist.txt` is the authoritative one-name-or-variant-per-line exclusion list. `entity-aliases.json` contains `clubs`, a single `players` list, exact `sibling_groups`, and normalized `common_surnames`. A player entry without `current_clubs` canonicalizes that name globally in reports; an entry with `current_clubs` applies only to enrichment requests whose canonical current club matches, mapping surname-only reports to the full canonical name. Qwen is instructed to preserve stated given names for common surnames, but the JavaScript digest filter is authoritative. Current requests precede historical retries under the 25-item enrichment cap; retries still only piggyback on runs that reach the enrichment query. Regenerate and re-import after registry edits; never edit generated workflow JSON directly.
