# Graph Report - .  (2026-07-26)

## Corpus Check
- 22 files · ~1,839,382 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 251 nodes · 360 edges · 13 communities (9 shown, 4 thin omitted)
- Extraction: 98% EXTRACTED · 2% INFERRED · 0% AMBIGUOUS · INFERRED: 6 edges (avg confidence: 0.78)
- Token cost: 11,216 input · 6,360 output

## Community Hubs (Navigation)
- Schema Validation Types
- Workflow Logic and Tests
- Deployment and Sources
- Transfer Status Enums
- Workflow Generator
- Transfer Report Fields
- Qwen Response Schema
- Mock API Services
- Qwen Acceptance Tests
- Delivery Safety
- Model Download
- E2E Test Runner
- Exported Report Fields

## God Nodes (most connected - your core abstractions)
1. `required` - 22 edges
2. `mainWorkflow()` - 18 edges
3. `null` - 15 edges
4. `validateQwenResponse()` - 9 edges
5. `string` - 8 edges
6. `parseRapidApiPosts()` - 7 edges
7. `enum` - 7 edges
8. `enum` - 7 edges
9. `enum` - 7 edges
10. `Football Transfer Monitor` - 7 edges

## Surprising Connections (you probably didn't know these)
- `source()` --calls--> `sourceMetadata()`  [EXTRACTED]
  tests/unit/workflow-lib.test.mjs → workflow/lib.mjs
- `Football Transfer Monitor` --references--> `PostgreSQL persistence layer`  [EXTRACTED]
  README.md → database/README.md
- `Football Transfer Monitor` --references--> `llama.cpp Qwen3.6-27B service`  [EXTRACTED]
  README.md → deploy/qwen3.6-27b/README.md
- `Football Transfer Monitor` --references--> `Repository test strategy`  [EXTRACTED]
  README.md → tests/README.md
- `Restart-safe Discord delivery` --conceptually_related_to--> `Transactional digest reservation safety`  [INFERRED]
  README.md → database/README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Production services connected through transfers_net** — deploy_n8n_compose_n8n, deploy_qwen3_6_27b_compose_llama, deploy_support_compose_transfers_postgres, deploy_n8n_compose_transfers_net [EXTRACTED 1.00]
- **Isolated mock end-to-end stack** — tests_e2e_compose_n8n, tests_e2e_compose_postgres, tests_e2e_compose_mock_services [EXTRACTED 1.00]
- **Source registry, prompt, and workflow extraction contract** — docs_journalist_list_source_registry, workflow_qwen_system_prompt_transfer_extraction_prompt, workflow_readme_extraction_contract, deploy_qwen3_6_27b_compose_llama [INFERRED 0.85]

## Communities (13 total, 4 thin omitted)

### Community 0 - "Schema Validation Types"
Cohesion: 0.05
Nodes (56): boolean, integer, null, number, string, minimum, type, pattern (+48 more)

### Community 1 - "Workflow Logic and Tests"
Cohesion: 0.08
Nodes (47): digest, recovered, reports, source(), AGREEMENT_STATES, buildDiscordDigest(), chooseClassification(), CLASSIFICATION_PRECEDENCE (+39 more)

### Community 2 - "Deployment and Sources"
Cohesion: 0.08
Nodes (32): Deterministic report deduplication, PostgreSQL persistence layer, n8n service, n8n external task runner, transfers_net network, n8n deployment, llama service, Idle model and KV-cache unloading (+24 more)

### Community 3 - "Transfer Status Enums"
Cohesion: 0.08
Nodes (27): advanced_negotiations, close, contract_renewal, failed, loan, negotiating, not_reported, official_confirmed (+19 more)

### Community 4 - "Workflow Generator"
Cohesion: 0.15
Nodes (26): candidatesSql(), codeNode(), digestCode(), errorOutputPath, errorWorkflow(), finalizeDeliverySql(), here, httpNode() (+18 more)

### Community 5 - "Transfer Report Fields"
Cohesion: 0.09
Nodes (22): add_ons_amount, add_ons_currency, agreement_status, classification, confidence, contract_expires_on, contract_length_months, current_club_name (+14 more)

### Community 6 - "Qwen Response Schema"
Cohesion: 0.12
Nodes (15): reports, transfer_related, additionalProperties, additionalProperties, type, properties, reports, transfer_related (+7 more)

### Community 8 - "Qwen Acceptance Tests"
Cohesion: 0.83
Nodes (3): check_gpu_offload(), test-server.sh script, wait_for_health()

### Community 9 - "Delivery Safety"
Cohesion: 0.67
Nodes (3): Transactional digest reservation safety, Restart-safe Discord delivery, Retry and delivery rules

## Knowledge Gaps
- **90 isolated node(s):** `download-model.sh script`, `state`, `validExtraction`, `run.sh script`, `reports` (+85 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **4 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `properties` connect `Schema Validation Types` to `Transfer Status Enums`, `Qwen Response Schema`?**
  _High betweenness centrality (0.181) - this node is a cross-community bridge._
- **Why does `items` connect `Qwen Response Schema` to `Schema Validation Types`, `Transfer Report Fields`?**
  _High betweenness centrality (0.110) - this node is a cross-community bridge._
- **Why does `required` connect `Transfer Report Fields` to `Qwen Response Schema`?**
  _High betweenness centrality (0.074) - this node is a cross-community bridge._
- **What connects `download-model.sh script`, `state`, `validExtraction` to the rest of the system?**
  _90 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Schema Validation Types` be split into smaller, more focused modules?**
  _Cohesion score 0.05194805194805195 - nodes in this community are weakly interconnected._
- **Should `Workflow Logic and Tests` be split into smaller, more focused modules?**
  _Cohesion score 0.07616892911010557 - nodes in this community are weakly interconnected._
- **Should `Deployment and Sources` be split into smaller, more focused modules?**
  _Cohesion score 0.07862903225806452 - nodes in this community are weakly interconnected._