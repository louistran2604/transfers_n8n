# Graph Report - .  (2026-07-26)

## Corpus Check
- 13 files · ~57,969 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 48 nodes · 55 edges · 7 communities (6 shown, 1 thin omitted)
- Extraction: 93% EXTRACTED · 7% INFERRED · 0% AMBIGUOUS · INFERRED: 4 edges (avg confidence: 0.92)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- Shared Docker Services
- X Source Collection
- Persistence and Delivery
- Monitor Policies
- Transfermarkt Enrichment
- Model Acceptance Tests
- Model Download Verification

## God Nodes (most connected - your core abstractions)
1. `Football Transfer Monitor Current-State Handoff` - 10 edges
2. `Football Transfer Monitor` - 5 edges
3. `Transfermarkt Player Profile Reference` - 5 edges
4. `External Docker Network transfers_net` - 4 edges
5. `GPU llama.cpp Server` - 4 edges
6. `test-server.sh script` - 3 edges
7. `Six-Hour Transfer Digest Workflow` - 3 edges
8. `Source-Preserving Report Merge` - 3 edges
9. `Transfer Source Priority Policy` - 3 edges
10. `Restart-Safe Deduplication` - 3 edges

## Surprising Connections (you probably didn't know these)
- `Transfer Source Priority Policy` --semantically_similar_to--> `Source-Preserving Report Merge`  [INFERRED] [semantically similar]
  current_state.md → README.md
- `Locked Six-Hour Schedule` --semantically_similar_to--> `Six-Hour Transfer Digest Workflow`  [INFERRED] [semantically similar]
  current_state.md → README.md
- `Playwright Transfermarkt Scraper` --references--> `Transfermarkt Player Profile Reference`  [EXTRACTED]
  current_state.md → transfermarkt_fields.pdf
- `n8n Service` --implements--> `External Docker Network transfers_net`  [EXTRACTED]
  deploy/n8n/compose.yaml → README.md
- `GPU llama.cpp Server` --implements--> `External Docker Network transfers_net`  [EXTRACTED]
  deploy/qwen3.6-27b/compose.yaml → README.md

## Import Cycles
- None detected.

## Hyperedges (group relationships)
- **Transfer Monitor Processing Pipeline** — current_state_rapidapi_x_collection, current_state_qwen_extraction_service, current_state_postgresql_16_persistence, current_state_discord_delivery_policy [EXTRACTED 1.00]
- **Services on transfers_net** — deploy_n8n_compose_n8n_service, deploy_qwen3_6_27b_compose_llama_service, readme_external_transfers_net [EXTRACTED 1.00]
- **Transfermarkt Enrichment Dataset** — transfermarkt_fields_player_identity_and_club_data, transfermarkt_fields_market_value_data, transfermarkt_fields_transfer_history, transfermarkt_fields_youth_clubs [EXTRACTED 1.00]

## Communities (7 total, 1 thin omitted)

### Community 0 - "Shared Docker Services"
Cohesion: 0.18
Nodes (12): Qwen Extraction Service, Persistent n8n Data Volume, n8n External Task Runner, n8n Service, GPU Inference Configuration, llama Health Check, GPU llama.cpp Server, Model-Service Acceptance Testing (+4 more)

### Community 1 - "X Source Collection"
Cohesion: 0.22
Nodes (10): RapidAPI X Post Collection, David Ornstein, Fabrizio Romano, Individual Journalist Accounts, News and Club Organization Accounts, X Source Account Registry, Fabrizio Romano Tweets Request Example, RapidAPI Tweets Endpoint (+2 more)

### Community 2 - "Persistence and Delivery"
Cohesion: 0.43
Nodes (7): Discord Digest Delivery Policy, PostgreSQL 16 Persistence Layer, Football Transfer Monitor Current-State Handoff, Restart-Safe Deduplication, Transfer Source Priority Policy, String-Typed X Identifiers, Transfer Classifications

### Community 3 - "Monitor Policies"
Cohesion: 0.40
Nodes (6): Locked Six-Hour Schedule, Football Transfer Monitor, Local Secret Isolation, Six-Hour Transfer Digest Workflow, Source-Preserving Report Merge, Transfermarkt Access Policy

### Community 4 - "Transfermarkt Enrichment"
Cohesion: 0.33
Nodes (6): Playwright Transfermarkt Scraper, Current Market Value Data, Player Identity and Current Club Data, Transfermarkt Player Profile Reference, Player Transfer History, Player Youth Clubs

### Community 5 - "Model Acceptance Tests"
Cohesion: 0.83
Nodes (3): check_gpu_offload(), test-server.sh script, wait_for_health()

## Knowledge Gaps
- **13 isolated node(s):** `download-model.sh script`, `Transfer Classifications`, `Discord Digest Delivery Policy`, `n8n External Task Runner`, `Persistent n8n Data Volume` (+8 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **1 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `Football Transfer Monitor Current-State Handoff` connect `Persistence and Delivery` to `Shared Docker Services`, `X Source Collection`, `Monitor Policies`, `Transfermarkt Enrichment`?**
  _High betweenness centrality (0.509) - this node is a cross-community bridge._
- **Why does `RapidAPI X Post Collection` connect `X Source Collection` to `Persistence and Delivery`?**
  _High betweenness centrality (0.258) - this node is a cross-community bridge._
- **What connects `download-model.sh script`, `Transfer Classifications`, `Discord Digest Delivery Policy` to the rest of the system?**
  _13 weakly-connected nodes found - possible documentation gaps or missing edges._