# n8n deployment

The n8n and external-runner images are pinned to matching n8n `2.16.1` manifests. The service joins `transfers_net` to reach PostgreSQL at `transfers-postgres:5432` and Qwen at `llama:8080`.

```bash
cd ~/projects/transfers_n8n/deploy/n8n
docker network create transfers_net
docker compose build
docker compose up -d
docker compose ps
docker compose logs -f n8n
```

The read-only `../../workflow` mount makes generated JSON available at `/workflows` for import:

```bash
docker compose exec -T n8n n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose exec -T n8n n8n import:workflow --input=/workflows/football-transfer-monitor.json
```

The existing local `.env` supplies the runner token, RapidAPI key, and Discord webhook URLs; keep it untracked. Create a Postgres credential named `Transfers PostgreSQL` in the n8n UI and map it to every Postgres node before activating the workflow. `RAPIDAPI_KEY` and both Discord webhook URLs remain environment expressions, never stored in workflow JSON.

Use `docker compose down` to stop n8n while preserving `bill_n8n_data`. Do not use `docker compose down --volumes` unless deleting n8n's stored workflows and credentials is intentional.
