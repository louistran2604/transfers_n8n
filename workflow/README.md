# Workflow generation and import

`build-workflows.mjs` is dependency-free and is the only source for the generated workflow JSON files. It parses `docs/journalist_list.md` directly, validates every account ID as a decimal string, and rejects a registry that does not contain exactly 78 accounts. It never reads collector sample requests for IDs.

```bash
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
```

Generated files:

- `football-transfer-monitor.json`: scheduled/manual collection, Qwen extraction, PostgreSQL merge, optional Sofascore enrichment, digest reservation, and Discord delivery.
- `football-transfer-monitor-errors.json`: n8n error trigger, PostgreSQL failure record, and error webhook.

Both workflows target n8n `2.16.1`, use `Asia/Ho_Chi_Minh`, and contain no secret values. They reference the intentionally missing PostgreSQL credential named `Transfers PostgreSQL`; map it after import in n8n.

## Extraction contract

`qwen-system-prompt.md` and `qwen-response-schema.json` are embedded verbatim into the generated workflow. The model may output only `transfer_related` and normalized report terms. Journalist/source identity, URL, platform, timestamp, priority, and reliability are injected from the normalized selected-collector post and generated source registry after model output, so Qwen cannot invent them.

## X collector selection

`X_COLLECTOR` must be explicitly `twscrape` or `rapidapi`. The generated `twscrape` branch submits all configured numeric X IDs as strings in one request, then adapts successful normalized posts into the existing raw-post SQL parameters. Its structured source failures produce no raw-post rows and do not stop successful sources. The retained RapidAPI branch keeps its existing per-source request and retry behavior. Both branches join before `Persist raw posts`; Qwen, PostgreSQL deduplication, report merging, digest reservation, and Discord delivery are unchanged.

Classification conflict precedence is: contract renewal, rejected/failed, loan, official/confirmed, advanced negotiations, then rumor. Fees and clauses are base-unit amounts, currencies are ISO codes, all report properties are required, and unknown nullable data is `null`.

## Optional Sofascore enrichment

`PLAYER_ENRICHMENT_MODE` accepts `off`, `shadow`, or `active`; a missing or invalid value is treated as `off`. The default `off` path goes directly from the preferred-source update to digest candidate loading and makes no enrichment context query or HTTP request. `shadow` resolves, fetches, and persists normalized enrichment without attaching it to digest candidates. `active` also left-joins eligible fresh snapshots, or failure-gated stale snapshots within the documented windows. Enrichment rendering is added separately.

The private request uses `SOFASCORE_ENRICHMENT_BASE_URL` (default `http://sofascore-enrichment:8080`), an 85-second n8n timeout, full responses, no HTTP retry, and at most 25 grouped items. Grouping uses a confirmed provider player ID or a Unicode reported-name plus verified club context, never the placeholder `players.id`. Context, service, contract, and enrichment-persistence failures rejoin `Prepare digest candidates query`; core PostgreSQL failure remains fatal because safe reservation depends on it.

Enrichment persistence is transactional and replay-safe. Canonical provider identity is kept on later report merges, while profile/statistics refreshes never enter the transfer snapshot hash, create a transfer revision, make a delivered revision eligible again, or trigger a resend. Discord reservation stores the exact request body in `digest_deliveries.request_payload`; conflict recovery returns and sends that stored body rather than rebuilding it.

## Retry and delivery rules

RapidAPI permits at most five attempts and Qwen at most three. The `twscrape` HTTP request has a finite 310-second timeout. The shared logic calculates bounded exponential delay and respects `Retry-After` or rate-reset headers. Discord is retryable only for an explicit `429` or `5xx`; a request interrupted after the network write is marked `unknown` and is never automatically resent.

The digest ranks confirmed transfers first, then Fabrizio Romano or David Ornstein reports, Qwen-marked huge rumors between major clubs, reported €70m/£70m rumors, and all other transfer news. It has at most 15 normal stories; positions 16–18 are only confirmed transfers or Romano/Ornstein reports. It also caps output at 10 embeds, 25 fields per embed, 1,024 characters per field, and 6,000 aggregate embed characters.
