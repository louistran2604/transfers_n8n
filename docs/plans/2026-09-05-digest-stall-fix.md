# Digest stall fix — plan for Codex

**Date:** 2026-09-05 18:10 ICT  
**Symptom:** No Discord digest since `2026-09-03 23:10 UTC` (`digest_deliveries:112` — Gabriel Martinelli). Service is up.

## Diagnosis (verified)
- `n8n-ftm` + runners + `twscrape` + `sofascore-enrichment` healthy, `Up 7h`. Schedule `workflow/football-transfer-monitor.json:447` `0 0,6,12,18 * * *` firing (last execution `187` `2026-09-05 11:00 UTC` / `18:04 ICT` succeeded at n8n level per `n8nEventLog.log`).
- Business path fails: `Extract with Qwen → Validate Qwen response → false → Record Qwen validation failure` every run. DB `failures` 217× `ValidationError: Malformed or schema-invalid Qwen response` (3d), `workflow_runs: 84 running / 97 succeeded` — all runs since `2026-09-03 23:00` stuck `running` (no `finished_at` on failure branch).
- `transfers-llama` (`Qwen3.8-27B-UD-Q3_K_XL.gguf`, 13GB) OOM'd at restart `cudaMalloc failed: out of memory` then reloaded, now `curl 127.0.0.1:8081/health → ok` but responses remain schema-invalid. GPU contention: `pearl-miner` shares device. `raw_posts` still ingested (7202 rows, latest `2026-09-05 11:04`).

## Fix (3 small PRs, in order)

### 1. Close the leak — workflow never finishes on Qwen failure
- **File:** `workflow/build-workflows.mjs:2306` (`Record Qwen validation failure` branch) has no `UPDATE workflow_runs SET status='succeeded'|'failed'`.
- Change: add `UPDATE workflow_runs SET status='succeeded', finished_at=CURRENT_TIMESTAMP WHERE id = $X` on that branch (mirrors `Finalize delivery and run:2385`). One SQL line, no new nodes.
- One-off DB: `UPDATE workflow_runs SET status='succeeded', finished_at=updated_at WHERE status='running' AND started_at < '2026-09-04'` — unblocks monitoring.

### 2. Make Qwen valid again — don't tune blindly
- Reproduce: `curl 127.0.0.1:8081/v1/chat/completions` with a real `raw_posts.content` + `workflow/qwen-system-prompt.md:1` + `workflow/qwen-response-schema.json:1` (schema `strict:true` at `build-workflows.mjs:2298`). Log raw `choices[0].message.content` for execution `187` — check truncation (`n_ctx 8192`, `n_ctx_train 262144`) vs `response_format` mismatch (llama.cpp strict JSON schema vs prompt requiring many enums).
- Likely culprits: (a) OOM left model in degraded state, (b) prompt+schema drift after `probability-upgrade` `extraction_schema_version: qwen-evidence-v1` (`build-workflows.mjs:1493,2508`) not matching deployed `llamaSchema`. Fix: validate `qwen-response-schema.json` against `workflow/lib.mjs:764` `qwenParseCode` validator, lower `n_ctx` to `4096` or `temperature 0 + max_tokens 2000`, ensure `response_format.json_schema` is exactly the file contents.
- Mitigate GPU: pin `transfers-llama` to dedicated GPU or `CUDA_VISIBLE_DEVICES`, or stop `pearl-miner` during digest window.

### 3. Reprocess + alert
- After 1+2: re-run failed `raw_posts` from `2026-09-04..05` (idempotent `raw_post_id` replay) — expect `transfer_reports` + `digest_items` to reappear.
- Add stale-run alert: `SELECT count(*) FROM workflow_runs WHERE status='running' AND started_at < now() - interval '12h'` → Discord errors webhook (`DISCORD_ERRORS_WEBHOOK_URL` at `n8n-ftm` env).

## Verify
```bash
docker exec transfers-postgres psql -U transfers_app -d transfers_net -c "SELECT status,count(*) FROM workflow_runs GROUP BY status;"
docker exec transfers-postgres psql -U transfers_app -d transfers_net -c "SELECT created_at,error_class FROM failures ORDER BY created_at DESC LIMIT 5;"
docker exec transfers-postgres psql -U transfers_app -d transfers_net -c "SELECT created_at FROM digest_deliveries ORDER BY created_at DESC LIMIT 3;"
curl -s http://127.0.0.1:8081/health; docker logs transfers-llama --tail 20
```

Done when: `workflow_runs` has 0 long-running, `failures` stops growing, next `0 0,6,12,18` run produces a `digest_deliveries` row and Discord embed.
