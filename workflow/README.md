# Workflow generation and import

`build-workflows.mjs` is dependency-free and is the only source for the generated workflow JSON files. It parses `docs/journalist_list.md` directly, validates every account ID as a decimal string, and rejects a registry that does not contain exactly 78 accounts. It never reads collector sample requests for IDs.

```bash
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
```

Generated files:

- `football-transfer-monitor.json`: scheduled/manual collection, Qwen extraction, PostgreSQL merge, digest reservation, and Discord delivery.
- `football-transfer-monitor-errors.json`: n8n error trigger, PostgreSQL failure record, and error webhook.

Both workflows target n8n `2.16.1`, use `Asia/Ho_Chi_Minh`, and contain no secret values. They reference the intentionally missing PostgreSQL credential named `Transfers PostgreSQL`; map it after import in n8n.

## Extraction contract

`qwen-system-prompt.md` and `qwen-response-schema.json` are embedded verbatim into the generated workflow. The model may output only `transfer_related` and normalized report terms. Journalist/source identity, URL, platform, timestamp, priority, and reliability are injected from the normalized selected-collector post and generated source registry after model output, so Qwen cannot invent them.

## X collector selection

`X_COLLECTOR` must be explicitly `twscrape` or `rapidapi`. The generated `twscrape` branch submits all configured numeric X IDs as strings in one request, then adapts successful normalized posts into the existing raw-post SQL parameters. Its structured source failures produce no raw-post rows and do not stop successful sources. The retained RapidAPI branch keeps its existing per-source request and retry behavior. Both branches join before `Persist raw posts`; Qwen, PostgreSQL deduplication, report merging, digest reservation, and Discord delivery are unchanged.

Classification conflict precedence is: contract renewal, rejected/failed, loan, official/confirmed, advanced negotiations, then rumor. Fees and clauses are base-unit amounts, currencies are ISO codes, all report properties are required, and unknown nullable data is `null`.

## Retry and delivery rules

RapidAPI permits at most five attempts and Qwen at most three. The `twscrape` HTTP request has a finite 310-second timeout. The shared logic calculates bounded exponential delay and respects `Retry-After` or rate-reset headers. Discord is retryable only for an explicit `429` or `5xx`; a request interrupted after the network write is marked `unknown` and is never automatically resent.

The digest ranks confirmed transfers first, then Fabrizio Romano or David Ornstein reports, Qwen-marked huge rumors between major clubs, reported €70m/£70m rumors, and all other transfer news. It has at most 15 normal stories; positions 16–18 are only confirmed transfers or Romano/Ornstein reports. It also caps output at 10 embeds, 25 fields per embed, 1,024 characters per field, and 6,000 aggregate embed characters.

`entity-aliases.json` is the editable canonical-name registry for club variants, player variants, and sibling groups. The generator embeds it in the Qwen parser, merge node, and digest node. Add aliases there, regenerate the workflow, and re-import it; never edit generated workflow JSON directly.
