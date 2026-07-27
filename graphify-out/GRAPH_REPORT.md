# Graph Report - .  (2026-07-27)

## Corpus Check
- 17 files · ~81,876 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 317 nodes · 452 edges · 22 communities (14 shown, 8 thin omitted)
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 18 edges (avg confidence: 0.8)
- Token cost: 6,544 input · 5,650 output

## Community Hubs (Navigation)
- Mock E2E Scenarios
- Schema Primitive Types
- Workflow Generation
- Transfer Status Enums
- twscrape HTTP Service
- Transfer Report Fields
- Monitoring Architecture
- n8n Deployment
- Qwen Response Schema
- twscrape Unit Tests
- E2E Test Stack
- Scraper Dependencies
- Mock API Server
- Qwen Health Checks
- RapidAPI Examples
- Model Download
- E2E Test Runner
- Report Deduplication
- Digest Reservation Safety
- Official Club Sources
- X Source Registry
- Report Field Exports

## God Nodes (most connected - your core abstractions)
1. `required` - 22 edges
2. `mainWorkflow()` - 19 edges
3. `null` - 15 edges
4. `validateQwenResponse()` - 9 edges
5. `string` - 8 edges
6. `Qwen Football Transfer Extractor` - 8 edges
7. `enum` - 7 edges
8. `enum` - 7 edges
9. `enum` - 7 edges
10. `on_startup()` - 7 edges

## Surprising Connections (you probably didn't know these)
- `Six-Hour Collection Pipeline` --semantically_similar_to--> `Generated Football Transfer Monitor Workflow`  [INFERRED] [semantically similar]
  README.md → workflow/README.md
- `source()` --calls--> `sourceMetadata()`  [EXTRACTED]
  tests/unit/workflow-lib.test.mjs → workflow/lib.mjs
- `Discord Digest Limits` --conceptually_related_to--> `Restart-Safe Discord Delivery`  [INFERRED]
  workflow/README.md → README.md
- `transfers_net Network` --semantically_similar_to--> `External transfers_net Network`  [INFERRED] [semantically similar]
  deploy/n8n/README.md → deploy/n8n/compose.yaml
- `Pre-Commit Secret Assignment Scan` --conceptually_related_to--> `Environment-Only Collector and Webhook Credentials`  [INFERRED]
  tests/README.md → deploy/n8n/README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Production n8n Service Topology** — deploy_n8n_compose_n8n_service, deploy_n8n_compose_n8n_runner_service, deploy_n8n_compose_twscrape_service, deploy_n8n_compose_transfers_net [EXTRACTED 1.00]
- **Isolated E2E Stack** — tests_e2e_compose_postgres_service, tests_e2e_compose_mock_services, tests_e2e_compose_n8n_service [EXTRACTED 1.00]
- **Qwen Extraction Policy** — workflow_qwen_system_prompt_mens_senior_scope, workflow_qwen_system_prompt_non_invention_policy, workflow_qwen_system_prompt_normalized_transfer_values, workflow_qwen_system_prompt_classification_precedence, workflow_qwen_system_prompt_external_source_metadata [EXTRACTED 1.00]

## Communities (22 total, 8 thin omitted)

### Community 0 - "Mock E2E Scenarios"
Cohesion: 0.07
Nodes (52): digest, recovered, reports, runTwscrapeAdapter, twscrapeAdapter, twscrapeRequest, womenExtraction, workflow (+44 more)

### Community 1 - "Schema Primitive Types"
Cohesion: 0.05
Nodes (56): boolean, integer, null, number, string, minimum, type, pattern (+48 more)

### Community 2 - "Workflow Generation"
Cohesion: 0.13
Nodes (29): candidatesSql(), codeNode(), digestCode(), errorOutputPath, errorWorkflow(), finalizeDeliverySql(), here, httpNode() (+21 more)

### Community 3 - "Transfer Status Enums"
Cohesion: 0.08
Nodes (27): advanced_negotiations, close, contract_renewal, failed, loan, negotiating, not_reported, official_confirmed (+19 more)

### Community 4 - "twscrape HTTP Service"
Cohesion: 0.21
Nodes (18): Any, API, Application, as_utc_iso(), collect_handler(), Collector, configure_account(), create_app() (+10 more)

### Community 5 - "Transfer Report Fields"
Cohesion: 0.09
Nodes (22): add_ons_amount, add_ons_currency, agreement_status, classification, confidence, contract_expires_on, contract_length_months, current_club_name (+14 more)

### Community 6 - "Monitoring Architecture"
Cohesion: 0.11
Nodes (20): Football Transfer Monitor, Material Report Revisions, Restart-Safe Discord Delivery, Six-Hour Collection Pipeline, Four-Tier Source Reliability Registry, Transfer Classification Precedence, Externally Supplied Source Metadata, Men's Senior Football Scope (+12 more)

### Community 7 - "n8n Deployment"
Cohesion: 0.12
Nodes (19): bill_n8n_data Volume, n8n External Runner Service, n8n Service, External transfers_net Network, twscrape_accounts Volume, twscrape Service, Environment-Only Collector and Webhook Credentials, n8n Deployment (+11 more)

### Community 8 - "Qwen Response Schema"
Cohesion: 0.12
Nodes (15): reports, transfer_related, additionalProperties, additionalProperties, type, properties, reports, transfer_related (+7 more)

### Community 9 - "twscrape Unit Tests"
Cohesion: 0.26
Nodes (4): FakeAPI, FakeTweet, source(), TwscrapeServiceTests

### Community 10 - "E2E Test Stack"
Cohesion: 0.40
Nodes (6): E2E Mock Services, n8n_e2e_data Volume, E2E n8n Service, E2E PostgreSQL Service, Isolated Mock E2E Validation, Test Strategy

### Community 11 - "Scraper Dependencies"
Cohesion: 0.40
Nodes (5): aiohttp 3.14.3, aiosqlite 0.22.1, httpx 0.28.1, twscrape 0.19.2, twscrape Dependency Lock

### Community 13 - "Qwen Health Checks"
Cohesion: 0.83
Nodes (3): check_gpu_offload(), test-server.sh script, wait_for_health()

### Community 14 - "RapidAPI Examples"
Cohesion: 0.50
Nodes (4): David Ornstein, Fabrizio Romano, RapidAPI Fabrizio Romano tweets request, RapidAPI David Ornstein tweets request

## Knowledge Gaps
- **116 isolated node(s):** `download-model.sh script`, `run.sh script`, `$schema`, `title`, `type` (+111 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **8 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `properties` connect `Schema Primitive Types` to `Qwen Response Schema`, `Transfer Status Enums`?**
  _High betweenness centrality (0.113) - this node is a cross-community bridge._
- **Why does `items` connect `Qwen Response Schema` to `Schema Primitive Types`, `Transfer Report Fields`?**
  _High betweenness centrality (0.069) - this node is a cross-community bridge._
- **Why does `required` connect `Transfer Report Fields` to `Qwen Response Schema`?**
  _High betweenness centrality (0.046) - this node is a cross-community bridge._
- **What connects `download-model.sh script`, `run.sh script`, `$schema` to the rest of the system?**
  _116 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Mock E2E Scenarios` be split into smaller, more focused modules?**
  _Cohesion score 0.06704260651629072 - nodes in this community are weakly interconnected._
- **Should `Schema Primitive Types` be split into smaller, more focused modules?**
  _Cohesion score 0.05194805194805195 - nodes in this community are weakly interconnected._
- **Should `Workflow Generation` be split into smaller, more focused modules?**
  _Cohesion score 0.13333333333333333 - nodes in this community are weakly interconnected._