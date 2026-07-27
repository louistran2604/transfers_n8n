# n8n deployment

The n8n and external-runner images are pinned to matching n8n `2.16.1` manifests. The service joins `transfers_net` to reach PostgreSQL at `transfers-postgres:5432` and Qwen at `llama:8080`. The optional `twscrape` profile joins only `transfers_net` and has no published host port.

```bash
cd ~/projects/transfers_n8n/deploy/n8n
docker network create transfers_net
docker compose --profile twscrape build twscrape
docker compose --profile twscrape up -d
docker compose ps
docker compose logs -f n8n
```

The read-only `../../workflow` mount makes generated JSON available at `/workflows` for import:

```bash
docker compose exec -T n8n n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose exec -T n8n n8n import:workflow --input=/workflows/football-transfer-monitor.json
```

The ignored local `.env` supplies the runner token, `X_COLLECTOR`, Discord webhook URLs, and either the dedicated-account `TWSCRAPE_AUTH_TOKEN`/`TWSCRAPE_CT0` values or `RAPIDAPI_KEY`. `X_COLLECTOR` must explicitly be `twscrape` or `rapidapi`; only the selected collector is required at runtime. Create a Postgres credential named `Transfers PostgreSQL` in the n8n UI and map it to every Postgres node before activating the workflow. Collector credentials and Discord webhooks remain environment expressions, never stored in workflow JSON.

For `twscrape`, copy the two cookie values from browser storage for `https://x.com` into the ignored `.env`, then check the private service without exposing a port:

```bash
docker compose exec -T twscrape python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).read().decode())"
```

If the account expires, update only the ignored cookie variables and recreate `twscrape` with `docker compose --profile twscrape up -d --force-recreate twscrape`. Keep its SQLite volume; it preserves account state and is refreshed when the cookie values change.

Use `docker compose down` to stop n8n while preserving `bill_n8n_data`. Do not use `docker compose down --volumes` unless deleting n8n's stored workflows and credentials is intentional.
