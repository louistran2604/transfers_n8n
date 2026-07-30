# n8n deployment

The n8n and external-runner images are pinned to matching n8n `2.16.1` manifests. The service joins `transfers_net` to reach PostgreSQL at `transfers-postgres:5432`, Qwen at `llama:8080`, and the optional Sofascore enrichment service at `sofascore-enrichment:8080`. The optional `twscrape` and `enrichment` profile services join only `transfers_net` and have no published host ports.

```bash
cd ~/projects/transfers_n8n/deploy/n8n
docker network create transfers_net
docker compose --profile twscrape build twscrape
docker compose --profile twscrape up -d
docker compose ps
docker compose logs -f n8n
```

Build and start the private enrichment service separately. n8n has no Compose dependency on it and continues with transfer-only behavior when enrichment is off or unavailable:

```bash
PLAYER_ENRICHMENT_MODE=off docker compose build sofascore-enrichment
PLAYER_ENRICHMENT_MODE=off docker compose up -d sofascore-enrichment
docker compose ps
docker compose logs --tail=200 sofascore-enrichment
```

Check liveness and offline readiness from inside the private container:

```bash
docker compose exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/healthz', timeout=2).read().decode())"
docker compose exec -T sofascore-enrichment \
  python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=2).read().decode())"
```

Readiness verifies the pinned `soccerdata` package, baked native TLS library, writable cache, fixture manifest, and provider child without contacting Sofascore. The service runs as UID/GID `10001`, has no browser, database credentials, Discord webhooks, X credentials, Qwen credentials, or GPU, and starts with limits of 1 CPU and 1 GiB memory.

The read-only `../../workflow` mount makes generated JSON available at `/workflows` for import:

```bash
docker compose exec -T n8n n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose exec -T n8n n8n import:workflow --input=/workflows/football-transfer-monitor.json
```

The ignored local `.env` supplies the runner token, `X_COLLECTOR`, Discord webhook URLs, and either the dedicated-account `TWSCRAPE_AUTH_TOKEN`/`TWSCRAPE_CT0` values or `RAPIDAPI_KEY`. `X_COLLECTOR` must explicitly be `twscrape` or `rapidapi`; only the selected collector is required at runtime. Create a Postgres credential named `Transfers PostgreSQL` in the n8n UI and map it to every Postgres node before activating the workflow. Collector credentials and Discord webhooks remain environment expressions, never stored in workflow JSON.

`PLAYER_ENRICHMENT_MODE` defaults to `off`. Keep it `off` until the documented provider-policy, fixture, test, and shadow gates pass. The other supported values are `shadow` (persist but do not render) and `active` (persist and render); changing the mode requires recreating n8n. The enrichment service itself needs no secrets.

For `twscrape`, copy the two cookie values from browser storage for `https://x.com` into the ignored `.env`, then check the private service without exposing a port:

```bash
docker compose exec -T twscrape python -c "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8080/health', timeout=2).read().decode())"
```

If the account expires, update only the ignored cookie variables and recreate `twscrape` with `docker compose --profile twscrape up -d --force-recreate twscrape`. Keep its SQLite volume; it preserves account state and is refreshed when the cookie values change.

The named `sofascore_cache` volume preserves the raw provider cache when the service is recreated or upgraded:

```bash
PLAYER_ENRICHMENT_MODE=off docker compose build sofascore-enrichment
PLAYER_ENRICHMENT_MODE=off docker compose up -d --force-recreate sofascore-enrichment
```

To reset only that raw cache, first keep the mode off and stop the service. Confirm the exact Compose-resolved volume name before deleting it:

```bash
PLAYER_ENRICHMENT_MODE=off docker compose stop sofascore-enrichment
docker volume inspect bill_sofascore_cache
docker volume rm bill_sofascore_cache
PLAYER_ENRICHMENT_MODE=off docker compose up -d sofascore-enrichment
```

This reset leaves normalized PostgreSQL snapshots intact. Do not use `docker compose down --volumes`; it would also delete n8n and collector data. Roll back the deployment by setting `PLAYER_ENRICHMENT_MODE=off`, recreating n8n, stopping `sofascore-enrichment`, and restoring the prior n8n/service images or workflow files. Retain `sofascore_cache` until deletion is explicitly approved.

Use `docker compose down` to stop n8n while preserving named volumes.
