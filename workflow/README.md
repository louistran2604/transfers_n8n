# Workflow generation and import

`build-workflows.mjs` is dependency-free and is the only source for the generated workflow JSON files. It parses `docs/journalist_list.md` directly, validates every account ID as a decimal string, and rejects a registry that does not contain exactly 77 accounts. It never reads RapidAPI sample requests for IDs.

```bash
node workflow/build-workflows.mjs
node workflow/build-workflows.mjs --check
```

Generated files:

- `football-transfer-monitor.json`: scheduled/manual collection, Qwen extraction, PostgreSQL merge, digest reservation, and Discord delivery.
- `football-transfer-monitor-errors.json`: n8n error trigger, PostgreSQL failure record, and error webhook.

Both workflows target n8n `2.16.1`, use `Asia/Ho_Chi_Minh`, and contain no secret values. They reference the intentionally missing PostgreSQL credential named `Transfers PostgreSQL`; map it after import in n8n.

## Extraction contract

`qwen-system-prompt.md` and `qwen-response-schema.json` are embedded verbatim into the generated workflow. The model may output only `transfer_related` and normalized report terms. Journalist/source identity, URL, platform, timestamp, priority, and reliability are injected from the RapidAPI post and generated source registry after model output, so Qwen cannot invent them.

Classification conflict precedence is: contract renewal, rejected/failed, loan, official/confirmed, advanced negotiations, then rumor. Fees and clauses are base-unit amounts, currencies are ISO codes, all report properties are required, and unknown nullable data is `null`.

## Retry and delivery rules

RapidAPI permits at most five attempts and Qwen at most three. The shared logic calculates bounded exponential delay and respects `Retry-After` or rate-reset headers. Discord is retryable only for an explicit `429` or `5xx`; a request interrupted after the network write is marked `unknown` and is never automatically resent.

The digest has at most 15 normal stories. Positions 16–18 are only official/confirmed or tier-1/2 advanced reports. It also caps output at 10 embeds, 25 fields per embed, 1,024 characters per field, and 6,000 aggregate embed characters.
