# Football-transfer probability upgrade plan

Status: planning only; no implementation changes are included.

Research date: 2026-08-27 (Asia/Ho_Chi_Minh). TransferTracker pages reported data as of 2026-08-26.

## Executive recommendation

Extend the existing restart-safe pipeline instead of replacing it:

```text
X posts
  -> Qwen evidence extraction (no probability)
  -> immutable per-post evidence ledger
  -> PostgreSQL case recomputation under a row lock
       -> per-destination raw probability
       -> destination/stay normalization
       -> explanation + probability revision
  -> existing optional Sofascore enrichment
  -> existing digest reservation/idempotency flow
  -> Discord probability delta + short explanation
```

Keep `transfer_reports`, `transfer_report_revisions`, `digest_deliveries`, and `digest_items` as the current projection and delivery backbone. They already provide deterministic deduplication, immutable material revisions, and restart-safe Discord delivery (`database/migrations/001_initial_schema.sql:70`, `database/migrations/001_initial_schema.sql:137`, `database/migrations/001_initial_schema.sql:224`, `database/migrations/001_initial_schema.sql:249`).

The smallest correct architectural addition is:

1. an immutable evidence row for every extracted claim;
2. a case row grouping one player/current-club/window across competing destinations;
3. a versioned deterministic PostgreSQL probability function;
4. a separate probability-revision ledger, with only material changes promoted into the existing digest revision flow.

Do not make TransferTracker a production dependency now. Its standard RSS feed is stable enough for an optional shadow/discovery adapter, but its richer JSON is an undocumented Supabase client contract and is too fragile for required ingestion.

## Scope and probability semantics

The percentage must mean:

> Probability that the named player completes the named move before the current transfer case/window closes, given evidence collected by the system as of the recorded evaluation time.

It is not Qwen's confidence that it parsed a post correctly, not a reporter's trust score, and not a general estimate that the story is "credible."

Material assumptions:

- PostgreSQL remains authoritative for deduplication, case state, probability calculation, revisions, and delivery reservation.
- The existing 78-source registry remains authoritative; new metadata augments it rather than creating another collector list (`workflow/README.md:3`, `workflow/lib.mjs:641`).
- Official confirmation is an externally observable terminal fact and is the only automatic route to 100%.
- A reporter-grade "done" claim is capped below 100%.
- Fee/market-value context is explanatory in the first release and does not change probability.
- Currency conversion is out of scope initially. Compute a ratio only when fee and market value share a currency.
- Old reports remain readable and deliverable; they are not silently assigned invented historical probabilities.

## TransferTracker findings that materially change the plan

### Verified from public pages and responses

- The published methodology describes a two-gate model: player/personal terms and club/fee agreement are scored separately. It says reporter history, independence, recency, and progression affect probability; official confirmation is 100%, while a reporter-grade done call remains 98%. It also says destination shares sum to 100%. [TransferTracker methodology](https://transfertracker.ai/methodology)
- Transfer pages expose an explicit progression timeline and source-by-source evidence. A current page showed `Link -> Interest -> Advanced` at 62%; another showed `Link -> Interest -> Advanced -> Agreed -> Corroborated -> Here we go` at 96%, together with reported fee versus market value. [Grealish example](https://transfertracker.ai/transfer/jack-grealish/manchester-city-to-sunderland/2026), [Uduokhai example](https://transfertracker.ai/transfer/felix-uduokhai/besiktas-to-union-berlin/2026)
- Reporter pages and the scorecard expose trust, landed, collapsed, and live counts, and describe resolved calls as being checked against completed transfers rather than against the site's own probability. [David Ornstein scorecard](https://transfertracker.ai/reporters/david-ornstein), [all reporters](https://transfertracker.ai/scorecard)
- A public RSS endpoint exists at `/feed.xml`. Items contain a stable transfer URL, publication time, a probability in the title, and a short summary. They do not provide a structured source/evidence breakdown. [TransferTracker RSS](https://transfertracker.ai/feed.xml)
- The browser bundle exposes public Supabase reads from views including `app_rumour` and `sources_credibility`. On inspection, `app_rumour.data` included source trust, claim kind, independence/originator flags, two gate states, setbacks, probability history, stage ceilings, applied signal values, credible-source counts, confidence intervals, and a destination/stay probability book. `sources_credibility` included priors, alpha/beta-like fields, hits, misses, recent hit rate, originality, and drift. [Inspected public client bundle](https://transfertracker.ai/assets/index-CStH70vO.js)
- Across 452 live rows observed through that client-accessible JSON, status medians were approximately: rumour 23%, agreed 72%, imminent 88%, confirmed 100%, collapsed 5%. All 450 rows with a destination book summed to exactly 1 across destinations, stay, and elsewhere. This is observation, not proof of the hidden formula.

### Evidence versus inference

Evidence:

- The public JSON contains applied signal values, priors, stage ceilings, context adjustments, echo amplification, and confidence intervals.
- The source view contains alpha/beta-like prior and updated fields plus hit/miss/recent-drift data.
- Same-story rows expose originator/echo/corroboration flags and exact normalized destination shares.

Inference:

- The probability engine appears to be a Bayesian/log-odds-style evidence accumulator with stage caps, source dependence handling, contextual modifiers, and a later competing-destination normalization step.
- The reporter model appears to use a Bayesian prior plus weighted outcomes and recent-drift adjustments.

Unknown:

- The exact server-side probability transformation, weighting, decay, context features, confidence-interval calculation, and manual correction rules are not published as a stable specification.
- The Supabase views are undocumented implementation details. A successful public read does not make them a stable API.

Plan consequence: copy the useful concepts, not the opaque percentages. Implement and version a simpler deterministic model whose complete formula is documented and regression-tested.

## 1. Recommended architecture and data-flow changes

### Preserve current boundaries

- `raw_posts` remains the original-post ledger (`database/migrations/001_initial_schema.sql:33`).
- `transfer_reports` remains one current projection per existing deterministic `dedupe_key` (`database/migrations/001_initial_schema.sql:70`).
- `transfer_report_sources` continues to retain every supporting post and the preferred-source pointer (`database/migrations/001_initial_schema.sql:119`).
- `transfer_report_revisions` remains the material version used by `digest_items` for exactly-once digest inclusion (`database/migrations/001_initial_schema.sql:137`).
- The current `sending -> unknown` recovery and frozen Discord payload rules remain unchanged (`workflow/lib.mjs:1269`, `workflow/build-workflows.mjs:1022`).

### Add three domain layers

1. **Evidence ledger**: one immutable/uniquely replayable extracted claim per `(raw_post_id, report_ordinal, extraction_schema_version)`. It preserves per-source stage, stance, gates, wording, attribution, and extraction quality instead of losing those details during merge.
2. **Transfer case**: one group per `(player_id, normalized_current_club, transfer_window_key)` containing all destination reports plus the stay alternative. Existing destination-specific `dedupe_key` values remain unchanged.
3. **Probability projection**: PostgreSQL recomputes all destinations in a case in one transaction, stores raw and normalized probabilities, and appends a versioned explanation revision.

### Transactional flow

After strict Qwen validation:

1. Upsert the player/report as today (`workflow/build-workflows.mjs:127`).
2. Insert the evidence row idempotently.
3. Lock the case row with `SELECT ... FOR UPDATE`.
4. Read the case's current evidence plus reporter-reliability snapshots.
5. Run `recompute_transfer_case(case_id, evaluated_at, engine_version)`.
6. Update every destination projection and append probability revisions only where the computed hash changed.
7. Create an existing material `transfer_report_revision` only when the stage changes, official/collapsed state changes, normalized probability moves by at least 5 percentage points, the leading destination changes, or fee context materially changes.

This keeps small decay changes auditable without turning every one-point movement into a Discord item.

### Engine location

Put the authoritative formula in PostgreSQL migration-owned functions, not Qwen and not a new microservice. The database already owns merge/revision consistency, and case-level row locking prevents concurrent posts from computing mutually stale destination shares. Keep Discord rendering and Qwen contract validation in the existing pure JavaScript helpers (`workflow/lib.mjs:764`, `workflow/lib.mjs:1240`).

## 2. Probability-engine design and proposed formula

### 2.1 Inputs that Qwen may classify

- stage signal;
- supports/contradicts/neutral stance;
- claim wording strength;
- club/fee gate state;
- personal-terms gate state;
- completion/official wording;
- attribution/originator versus cited/aggregated source;
- parsing confidence, renamed `extraction_confidence`.

Qwen never emits a transfer percentage, probability contribution, reporter trust score, or independence count.

### 2.2 Reporter reliability

Use a transparent Beta-Binomial posterior:

```text
alpha0 = 8 * seed_reliability
beta0  = 8 * (1 - seed_reliability)

alpha = alpha0 + sum(success_weight)
beta  = beta0  + sum(failure_weight)

reporter_reliability = clamp(alpha / (alpha + beta), 0.55, 0.95)
```

The seed comes from the existing registry metadata, but official accounts are handled as official evidence rather than as 100%-reliable rumour reporters. The current hard-coded source defaults are 1.00 for two official usernames, 0.95 for tier-two usernames, 0.80 for organizations, and 0.70 otherwise (`workflow/lib.mjs:641`). Move those seeds into explicit registry metadata during the upgrade.

Score only destination-specific claims strong enough to be judged:

| First/highest eligible claim by a source in a case | Outcome weight |
| --- | ---: |
| Advanced talks | 0.50 |
| One/both gates agreed | 0.75 |
| Done / here-we-go | 1.00 |
| Link or interest | Not scored |
| Official club announcement | Outcome evidence, not a reporter prediction |

A success requires later official completion to that destination. A failure requires official completion elsewhere, an explicit collapse from authoritative evidence, or the window closing plus a 14-day settlement grace period. The engine's own probability can never settle reporter outcomes.

Count at most one weighted outcome per source/case/destination. Repeated posts may improve the stored stage but do not create multiple reliability wins or losses.

### 2.3 Source independence

Calculate an `independence_key` deterministically:

1. if a post explicitly cites a named originator that resolves to the registry, use that originator;
2. otherwise use the posting account;
3. collapse accounts in the same configured publisher/syndication group;
4. mark unresolved aggregations as `unknown`, which cannot add an independent corroboration boost.

Within one independence group, only the strongest newest applicable claim counts. A later stage progression from the same group can replace the earlier claim, but repetition cannot inflate corroboration.

### 2.4 Stage anchor

Derive current stage from the strongest current credible evidence and the two gates:

| Stage/gate state | Base probability | Maximum before competing-destination normalization |
| --- | ---: | ---: |
| Link | 10% | 25% |
| Interest | 18% | 45% |
| Talks | 35% | 65% |
| Advanced | 55% | 82% |
| Agreed: one gate | 72% | 90% |
| Agreed: both required gates | 90% | 97% |
| Done / announcement pending | 97% | 98% |
| Collapsed | 2% | 5% |
| Official confirmation | 100% | 100% |

For free transfers or contract renewals, the club/fee gate is marked `not_applicable`, not silently treated as missing. A reporter's word "official" does not create the official stage unless the source account is the relevant club/league or another explicitly configured authoritative confirmation source.

### 2.5 Deterministic log-odds adjustment

For a non-terminal destination:

```text
z = logit(stage_base)
  + primary_reliability_adjustment
  + independent_corroboration
  + contradiction_adjustment
  + staleness_adjustment

raw_probability = min(stage_ceiling, sigmoid(z))
```

Weights:

```text
primary_reliability_adjustment
  = clamp(2 * (r_primary - 0.75), -0.50, +0.50)
    * wording_factor
    * recency_factor

reliability_multiplier(r)
  = clamp((r - 0.50) / 0.45, 0.25, 1.00)

independent corroborator j beyond the primary
  = 0.65
    * reliability_multiplier(r_j)
    * wording_factor_j
    * recency_factor_j
    * diminishing_factor_j

diminishing_factor_j = 1.00, 0.70, 0.50, then 0.25 for later groups
```

Wording factors:

| Qwen classification | Factor |
| --- | ---: |
| Hedged/speculative | 0.75 |
| Reported/qualified | 0.90 |
| Direct factual claim | 1.00 |
| Definitive/done wording | 1.10 |

Contradictory evidence uses the same reporter, wording, recency, and independence multipliers with signed base values:

| Contradiction | Log-odds base |
| --- | ---: |
| Talks cooling / destination deprioritized | -0.60 |
| Bid rejected / terms rejected, talks may continue | -0.80 |
| Direct denial of the move | -1.60 |
| Explicit collapse | terminal 2%, capped at 5% |

Recency:

```text
recency_factor = 2 ^ (-age_days / half_life_days)
```

- 7 days for link/interest;
- 14 days for talks/advanced/denials;
- 30 days for agreed/done;
- no decay for official terminal outcomes.

If the newest supporting evidence is older than one half-life, apply an additional story-staleness adjustment of `-0.35` log-odds per extra half-life, capped at `-1.40`.

### 2.6 Competing-destination normalization

Keep both values:

- `raw_probability`: this destination against staying, before known rivals;
- `normalized_probability`: the displayed mutually exclusive share.

For destinations `i`:

```text
odds_i = raw_i / (1 - raw_i)
stay_odds = 1

normalized_i = odds_i / (stay_odds + sum(odds_all_destinations))
stay_probability = stay_odds / (stay_odds + sum(odds_all_destinations))
```

This preserves the raw probability when only one destination exists and guarantees that all known destinations plus stay sum to 100%. An official move locks its destination to 100% and every competitor/stay to 0%. An official renewal locks stay to 100%.

Store the normalization delta separately so an explanation can say that a destination fell because a competitor strengthened even though its own evidence did not change.

### 2.7 Explanation payload

Every probability revision stores:

```json
{
  "engine_version": "probability-v1",
  "evaluated_at": "...",
  "stage": {"name": "advanced", "base": 0.55, "ceiling": 0.82},
  "primary_source": {"source_account_id": 1, "reliability": 0.87, "adjustment": 0.24},
  "corroboration": [{"independence_key": "...", "adjustment": 0.51}],
  "contradictions": [{"kind": "bid_rejected", "adjustment": -0.63}],
  "staleness_adjustment": 0,
  "raw_probability": 0.68,
  "competition_adjustment": -0.06,
  "normalized_probability": 0.62,
  "previous_probability": 0.51,
  "delta": 0.11
}
```

All displayed prose is rendered from this payload using fixed templates.

## 3. How probabilities change when new reports arrive

Recompute the whole case whenever a new evidence row is inserted or an authoritative outcome/reliability snapshot changes.

| Incoming event | Required behavior |
| --- | --- |
| Same account repeats the same link | Evidence is retained; probability does not gain a corroboration boost. |
| Same account progresses from interest to advanced | Replace that independence group's active signal; stage/base may rise. |
| Independent high-reliability source corroborates | Add a positive diminishing log-odds contribution; record that source in the explanation. |
| Outlet repeats a named reporter's story | Map to the named reporter's independence key; no independent boost. |
| Newer lower-reliability contradiction | Apply a smaller negative contribution. |
| Newer high-reliability denial | Apply a larger negative contribution and allow stage regression. |
| Bid rejected | Lower probability moderately; do not mark collapsed unless the move is explicitly off. |
| One gate agreed | Promote to `agreed` with the one-gate base/ceiling. |
| Both required gates agreed | Raise the base/ceiling, normally into the high-probability band. |
| Reporter-grade done call | Promote to `done`, capped at 98%. |
| Relevant official account confirms | Set 100%, settle the case, and resolve reporter outcomes. |
| Explicit authoritative collapse | Set approximately 2%, settle or mark reopenable, and resolve eligible reporter outcomes. |
| Competing destination strengthens | Re-normalize every destination; unchanged destinations may get negative competition deltas. |
| Only time passes | Daily stale sweep may lower raw probability; record it, but do not create a Discord item unless the delta reaches 5 points or changes the leading destination. |

Stages may regress when newer contradictory evidence warrants it. `official` is terminal. `collapsed` may be reopened only by later evidence with a strictly later timestamp and at least `advanced` strength; the revision ledger must preserve the collapse and reopen event.

## 4. Database and schema changes

Add one migration, proposed as `database/migrations/003_transfer_probability.sql`, and register it in `database/migrate.sql`.

### `source_accounts` additions

- `seed_reliability numeric(5,4)`;
- `publisher_group_key text`;
- `source_kind text` (`journalist`, `publisher`, `club_official`, `league_official`, `aggregator`);
- `is_aggregator boolean`;
- keep existing `reliability_score` as a compatibility field during rollout (`database/migrations/001_initial_schema.sql:13`).

### `source_reliability_snapshots`

- source account, engine version, alpha, beta, effective resolved count, posterior reliability, calculated time;
- unique `(source_account_id, engine_version, calculated_at)` or current-version partial uniqueness;
- immutable history so an old probability revision can be reproduced.

### `source_claim_outcomes`

- source account, case, destination report, first eligible stage, claim time, settlement outcome, outcome weight, authoritative evidence post/revision, settled time;
- unique `(source_account_id, transfer_case_id, transfer_report_id)`;
- prohibit settlement from the probability engine itself.

### `transfer_cases`

- stable case key, player, normalized current club, transfer-window key, status, stay probability, engine version, lock/version counter, created/updated timestamps;
- unique case key;
- `transfer_reports.transfer_case_id` nullable during migration, then populated for newly scored reports.

### `transfer_evidence`

- report/case/raw post linkage;
- extraction schema version and ordinal;
- destination, stage signal, stance, wording strength;
- club gate, personal-terms gate, completion claim;
- attribution kind, named originator, resolved independence key;
- extraction confidence and raw normalized extraction JSON;
- unique replay key `(raw_post_id, report_ordinal, extraction_schema_version)`.

### `transfer_probability_revisions`

- report/case, sequential revision, engine version, evaluated time;
- raw probability, normalized probability, previous probability, delta;
- current stage, explanation JSON, input fingerprint;
- unique `(transfer_report_id, input_fingerprint, engine_version)`.

### `transfer_reports` additions

- `transfer_case_id`;
- `transfer_stage`;
- `raw_probability numeric(6,5)`;
- `normalized_probability numeric(6,5)`;
- `probability_engine_version`;
- `probability_explanation jsonb`;
- `probability_updated_at`;
- keep existing `confidence` for legacy reads; stop treating it as transfer probability (`workflow/lib.mjs:853`).

### Fee context

Do not duplicate the entire Sofascore profile. At projection/digest time, read the current enrichment view, which already exposes `market_value` and currency (`database/migrations/002_soccerdata_enrichment.sql:277`, `database/migrations/002_soccerdata_enrichment.sql:412`). Store the exact profile-snapshot identifier used in a probability/material revision plus:

- fee/market-value ratio when currencies match;
- guaranteed fee ratio and fee-plus-add-ons ratio where available;
- `market_value_as_of` and stale flag.

Market value does not enter `probability-v1`.

## 5. Qwen extraction and schema changes

The current prompt deliberately separates journalist/source metadata from model output (`workflow/qwen-system-prompt.md:13`), and already emits separate reports for competing destinations (`workflow/qwen-system-prompt.md:16`). Preserve both rules.

Replace model `confidence` with `extraction_confidence` and add required enums:

```text
stage_signal:
  link | interest | talks | advanced | agreed | done |
  setback | collapsed | official_wording | not_reported

claim_stance:
  supports | contradicts | neutral

wording_strength:
  hedged | reported | direct | definitive

club_agreement_state:
  not_reported | not_applicable | talks | agreed | rejected | collapsed

personal_terms_state:
  not_reported | talks | agreed | rejected

completion_claim:
  none | reporter_done | official_announcement

attribution_kind:
  original | cites_named_source | aggregation | unknown

named_originator:
  string | null
```

Prompt rules:

- classify only text present in the post;
- `official_announcement` describes wording, not trusted official status; the workflow verifies account authority;
- a rejected bid is `setback` plus `club_agreement_state=rejected`, not automatically `collapsed`;
- distinguish "personal terms agreed" from "clubs agreed a fee";
- copied/cited reporting must identify the named originator when explicit;
- never output a percentage, probability factor, reliability score, independence count, or explanation prose;
- keep all current direction, fee-unit, date, men's-senior, multi-destination, and no-invention rules (`workflow/qwen-system-prompt.md:5`, `workflow/qwen-system-prompt.md:7`, `workflow/qwen-system-prompt.md:8`, `workflow/qwen-system-prompt.md:9`).

During one compatibility release, validator/canonicalizer code may accept legacy `confidence` and map it to `extraction_confidence`, but newly generated Qwen requests must require the new field. Update both the reusable validator and embedded generated-workflow validator (`workflow/lib.mjs:764`, `workflow/build-workflows.mjs:1219`).

## 6. n8n and workflow changes

`workflow/build-workflows.mjs` remains the only workflow source; generated JSON is never edited directly (`workflow/README.md:3`).

Change the main path to:

1. collectors and raw-post persistence unchanged;
2. Qwen request uses the new schema;
3. strict validation/canonicalization produces evidence rows;
4. replace current max-confidence merge behavior with `Persist evidence and recompute case` transaction;
5. recomputation returns changed destination projections and material-change flags;
6. optional Sofascore flow remains `off|shadow|active` and enriches the projection as today (`workflow/build-workflows.mjs:1288`);
7. digest candidate query reads probability revisions/material revisions;
8. reservation, frozen request payload, Discord send, finalization, and interrupted-send recovery remain unchanged.

Add one bounded daily stale-case recomputation query. It must:

- select only live cases whose newest evidence crossed a half-life boundary;
- process a fixed batch;
- use the same function and engine version;
- avoid Discord eligibility for a pure decay change below 5 points.

Registry metadata should be explicit rather than hidden in username sets. Extend the authoritative source registry or an adjacent validated metadata section with publisher group, source kind, aggregator flag, and seed reliability; keep the exact-78-ID validation (`workflow/lib.mjs:641`).

Do not add a new probability service or dependency.

### TransferTracker ingestion decision

**Now:** no ingestion branch.

**Optional later:** a feature-flagged `off|shadow` RSS adapter for `https://transfertracker.ai/feed.xml`, used only for discovery/comparison. Treat TransferTracker as an aggregator independence group and never count its published percentage as evidence in this engine.

Do not depend on:

- HTML scraping;
- the hashed JavaScript bundle;
- the embedded Supabase publishable key;
- `app_rumour`, `sources_credibility`, or any other undocumented view;
- the bundle's `/app_data.json` fallback, which returned 404 during inspection.

Promote a JSON adapter only if TransferTracker publishes a documented endpoint with a stable schema, authentication/usage terms, identifiers, update semantics, and deprecation policy.

## 7. Discord output changes

Replace the current model-derived `Confidence: N%` line (`workflow/lib.mjs:1040`, `workflow/build-workflows.mjs:1793`) with a compact deterministic block:

```text
Probability: 62%  (▲ 11)
Stage: Advanced talks · fee talks, personal terms not reported
Why: strong primary report (87% reliability); +1 independent source;
     -6 pts after competing-destination normalization
Fee: €25m + €5m add-ons · Sofascore value €20m (1.25x, fresh)
```

Rendering rules:

- show `new% (delta)` only when a previous probability exists;
- use `▲`, `▼`, or `—` and signed integer percentage points;
- explanations are fixed templates from the stored breakdown, never Qwen prose;
- include at most two positive and one negative driver;
- explicitly say `competition` when another destination caused the delta;
- show reporter reliability with effective resolved count when space allows;
- display `Done · awaiting official announcement` at 98% maximum;
- display official confirmation as 100%;
- show fee/value ratio only for matching currencies and a sufficiently fresh market-value snapshot;
- preserve the existing 25-field, 6000-character, and 1024-character field limits and stored request payload behavior.

Digest materiality:

- always send official, collapsed, reopened, and leading-destination changes;
- send stage progression/regression;
- send probability movement only at absolute delta >= 5 points;
- do not send same-source repeats or small pure-decay movements;
- preserve existing revision uniqueness and delivery idempotency.

## 8. Migration and backward compatibility

### Additive deployment order

1. Apply migration with nullable/defaulted additions; old workflow must still write successfully.
2. Deploy new workflow in `PROBABILITY_MODE=shadow`.
3. Reprocess only recent raw posts (recommended 30 days) through the new Qwen schema, idempotently.
4. Compare probability revisions and explanations without changing Discord.
5. Enable Discord probability rendering after acceptance checks.
6. Stop writing new model `confidence`; retain legacy column until a later cleanup migration.

### Historical rows

Do not map every old `rumor` or `rejected_failed` row to a precise stage. Existing `rejected_failed` conflates a rejected offer and a collapsed move (`workflow/qwen-system-prompt.md:11`, `workflow/qwen-system-prompt.md:12`).

Safe mappings:

- official account + existing official classification -> official/100%;
- non-official completion claim -> done, below 100%;
- advanced negotiations -> advanced, unless recent raw posts are re-extracted with gate states;
- rumor/rejected/loan/renewal without sufficient evidence -> `legacy_unscored` until re-extracted.

For legacy Discord revisions, retain the old field as `Legacy extraction confidence` only if they must be resent from a frozen request payload. Never relabel it as probability.

### Rollback

- Reverting the workflow leaves additive tables/columns unused.
- Existing digest payloads remain frozen and replay-safe.
- The core workflow must continue to pass without Sofascore/enrichment tables, preserving the intent of `database/tests/004_enrichment_rollback_compatibility.sql`.
- Engine versions are immutable. Weight changes create `probability-v2`; they never rewrite v1 revisions.

## 9. Tests and verification

### Unit and contract tests

Add focused cases to `tests/unit/workflow-lib.test.mjs` and Qwen fixtures:

- every new enum and exact field set;
- no percentage/probability field allowed from Qwen;
- link versus interest versus talks versus advanced;
- bid rejected versus move collapsed;
- one gate agreed versus both gates agreed;
- reporter done wording versus verified official account;
- original report versus citation/aggregation;
- same player with multiple destinations remains separate;
- legacy `confidence` compatibility mapping.

### PostgreSQL engine tests

Add `database/tests/005_transfer_probability.sql` with exact numeric assertions:

- replaying evidence is idempotent;
- input order does not change output;
- same-source repetition does not boost corroboration;
- a genuinely independent source raises probability;
- higher reporter reliability creates a larger signed adjustment;
- newer equal evidence weighs more than stale evidence;
- bid rejection lowers but does not collapse;
- denial/collapse lower probability;
- reporter done never exceeds 98%;
- verified official confirmation is exactly 100%;
- every destination plus stay sums to 1 within `1e-9` before display rounding;
- strengthening one destination lowers competitors' normalized shares;
- explanation JSON sums/reconciles to the stored result;
- one source/case/destination creates at most one reliability outcome;
- reliability posterior uses only authoritative outcomes;
- probability revisions are unique by input fingerprint and engine version.

Property/invariant tests:

- probabilities remain in `[0,1]`;
- official is terminal;
- deterministic results for the same evidence, reliability snapshot, evaluation time, and engine version;
- no probability depends on Qwen extraction confidence except a hard minimum-quality gate for accepting/reviewing evidence.

### Migration tests

- migrate from 001-only and from 001+002 states;
- old workflow inserts still succeed after 003;
- recent-post backfill is idempotent;
- `legacy_unscored` rows remain digest-compatible;
- rollback to the old workflow ignores new columns/tables;
- generated workflow and source remain synchronized.

### End-to-end scenarios

Extend `tests/e2e/scenario.mjs` and its mock services:

1. first link -> low probability;
2. same-source repeat -> no boost;
3. independent advanced report -> stage/probability increase;
4. competing destination -> both shares re-normalize;
5. high-reliability denial -> drop and explanation;
6. reporter done -> <=98%;
7. official account -> 100%;
8. Sofascore same-currency value -> ratio shown;
9. currency mismatch/stale value -> no ratio;
10. Discord send interruption -> existing `unknown` recovery and no automatic duplicate.

Optional RSS adapter tests, if later approved:

- XML contract/ETag/timeout handling;
- duplicate GUID replay;
- schema drift disables shadow ingestion without affecting the X pipeline;
- TransferTracker percentage is stored only as external comparison metadata.

### Verification commands

Run narrowest to broadest:

1. `node --test tests/unit/workflow-lib.test.mjs`;
2. Qwen fixture validation without a live model, then the existing live extraction script when the model is available;
3. `node workflow/build-workflows.mjs --check`;
4. migration SQL suite including the new test;
5. Sofascore fixture/unit suite;
6. full mock e2e suite in `tests/e2e/run.sh`.

Success criteria:

- all invariants above pass;
- repeated runs create no duplicate evidence, probability revisions, digest items, or Discord deliveries;
- a fixed golden evidence fixture produces byte-stable explanation JSON for `probability-v1`;
- all normalized cases sum to exactly 1 before rounding;
- no generated workflow contains model-authored final probability;
- Discord remains within existing size limits.

## 10. Phased implementation order

### Implement now

1. **Add additive evidence/case/probability schema and exact SQL tests** -> verify: old workflow writes still pass, replay is idempotent, and case locking/revision uniqueness hold.
2. **Make source reliability and independence metadata explicit for the 78 existing accounts** -> verify: registry still contains exactly 78 unique decimal X IDs; every account resolves to one source/publisher group and a seed.
3. **Change Qwen from report-confidence output to evidence/stage/gate/attribution extraction** -> verify: strict schema fixtures cover positive, contradictory, official-wording, aggregation, and multi-destination cases; no final probability field is accepted.
4. **Implement `probability-v1` in PostgreSQL behind `PROBABILITY_MODE=shadow`** -> verify: golden numeric tests, permutation invariance, reporter reliability posterior, recency, contradiction, and 98/100 terminal rules pass.
5. **Add case-level destination/stay normalization and explanation revisions** -> verify: all cases sum to 1, single-destination raw probability is preserved, and competition-only deltas are identified.
6. **Run a 30-day idempotent re-extraction/backfill in shadow mode** -> verify: compare stage/probability distributions, manually review a stratified sample, and confirm no existing Discord output changes.
7. **Add Discord probability/stage/delta rendering and materiality thresholds** -> verify: size-limit tests and full interrupted-delivery e2e remain green before enabling active mode.
8. **Add fee-versus-Sofascore-value context without feeding it into probability** -> verify: matching-currency/freshness cases render ratios; mismatch/stale/missing enrichment fails open.
9. **Enable authoritative outcome settlement and reporter-posterior updates** -> verify: only official/collapse/window-settlement evidence resolves outcomes and historical revisions remain reproducible.

### Lower-value or speculative; defer

- TransferTracker JSON/Supabase ingestion: undocumented and fragile.
- TransferTracker RSS ingestion: stable enough for shadow discovery, but it adds no structured independent evidence and should wait until the native engine is stable.
- Market-value or fee plausibility as a probability feature: high risk of encoding subjective assumptions; show context first and calibrate later.
- Contract/age/club-context probability adjustments: TransferTracker appears to use them, but they require outcome calibration and are not necessary for v1.
- Confidence intervals: valuable after enough settled cases exist; do not fabricate statistical precision at launch.
- Recent-form/drift adjustment to reporter reliability: retain history now, add only after sample sizes and evaluation rules are proven.
- Automatic web verification beyond the configured X sources: broad scope and new reliability/security concerns.
- Public web transfer pages/dashboard: Discord and database correctness come first.

## Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| Qwen misclassifies a stage | Store immutable raw evidence, use strict enums, threshold `extraction_confidence` only for review, and make probability fully reproducible. |
| Repeated/syndicated stories inflate probability | Resolve named originator/publisher groups and count one active signal per independence key. |
| Reporter reliability becomes circular | Resolve outcomes only from official/collapse/window evidence, never engine predictions. |
| Multiple destinations exceed 100% | Normalize odds across all destinations plus stay in one locked case transaction. |
| Recency creates noisy Discord spam | Record every revision but digest only >=5-point pure probability movements or material state changes. |
| Concurrent posts race | Lock the case row and recompute all destinations transactionally. |
| Old data receives fake precision | Mark it `legacy_unscored`; re-extract only recent posts. |
| Sofascore value is stale or in another currency | Show timestamp/stale status and skip the ratio when comparison is invalid. |
| Engine tuning rewrites history | Immutable `engine_version`; new weights require a new version. |
| TransferTracker endpoint changes | No production dependency; optional RSS adapter is isolated and fail-open. |

## Acceptance criteria

- Qwen emits evidence classifications and extraction quality only; final percentages are impossible under the schema.
- Every displayed percentage can be recomputed from stored evidence, reporter snapshot, evaluation time, and engine version.
- Every probability change has a stored numeric breakdown and a deterministic short explanation.
- Same-origin repeats cannot add independent corroboration.
- Official confirmation is 100%; reporter done is never above 98%.
- Competing destinations plus stay always total 100% before rounding.
- Existing dedupe, material revision, digest reservation, frozen payload, and interrupted-send recovery semantics remain intact.
- Legacy rows and an old workflow deployment remain operational after the additive migration.
- TransferTracker is not required for collection, scoring, enrichment, or delivery.

