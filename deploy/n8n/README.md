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
docker compose -f ../support/compose.yaml --profile maintenance run --rm transfers-db-migrate
PLAYER_ENRICHMENT_MODE=off docker compose up -d sofascore-enrichment
PLAYER_ENRICHMENT_MODE=off docker compose up -d --force-recreate n8n
docker compose ps
docker compose logs --tail=200 sofascore-enrichment
```

Run these from `deploy/n8n` as shown above. Apply migration 002 before importing or running a workflow that references its objects.

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

| Mode | Enrichment service call | Enrichment writes | Digest output |
| --- | --- | --- | --- |
| `off` | No | No | Transfer-only |
| `shadow` | Yes | Yes | Transfer-only |
| `active` | Yes | Yes | Eligible fresh/stale data appended |

A missing or invalid value is treated as `off`. Do not use `shadow` before provider access-policy approval. Do not use `active` until the complete offline suite, gated live acceptance, 28 reviewed shadow runs, identity/mapping review, forced all-failure proof, and resource measurements pass.

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

## Monitoring and resource gate

Use the private readiness response and structured service logs to inspect request duration, provider/cache calls, cache hits/misses/quarantine, item outcomes, circuit state, child restarts, queue depth, and the last provider success. Never paste raw provider payloads, player-name queries, reports, cookies, or webhook values into logs or tickets.

The initial limit is 1 CPU and 1 GiB with no GPU. Before active mode, measure a 25-item batch and record p95 latency, deadline rate, CPU, RSS, cache growth, and child churn. The release gate is p95 at most 60 seconds, no batch beyond the 75-second service budget, and no OOM/restart churn. Change the Compose limit only from recorded evidence.

## Rollout and rollback

1. Run the complete fixture-backed suite with provider networking blocked and mode off.
2. After provider-policy approval, run the separately gated serial read-only live acceptance with disposable cache and no database or Discord writes.
3. Dark-deploy migration 002, service, cache, and workflows in mode off; the provider-call counter must remain zero.
4. Run shadow for at least 7 days and 28 scheduled runs, reviewing identities, unusual mappings, calls, schemas, deadlines, and resources.
5. Exercise rich, sparse, stale, ambiguous, all-failure, and maximum-size output against a test webhook/database before one monitored active run.

Rollback immediately for a wrong identity, enrichment-caused digest failure/duplicate, frozen-payload mutation, schema/cache loop, repeated timeout/circuit, request amplification, native checksum anomaly, OOM, or provider-policy concern:

```bash
# First set PLAYER_ENRICHMENT_MODE=off in the ignored deploy/n8n/.env.
PLAYER_ENRICHMENT_MODE=off docker compose up -d --force-recreate n8n
PLAYER_ENRICHMENT_MODE=off docker compose stop sofascore-enrichment
```

Confirm transfer-only reservation and delivery in a test environment, then restore the recorded prior workflow/n8n/service image artifacts. Retain migration 002, snapshots, attempts, and raw cache unless deletion is separately approved. Never release digest items or automatically resend an `unknown` delivery.

## Dependency upgrade

Never float soccerdata, aiohttp, Python/base image, the native TLS asset, or n8n. For an upgrade:

1. Retain the current image and inspect the new upstream source, tests, Python support, endpoint schemas, and inherited public API.
2. Update `requirements.in`; regenerate and review the hash-locked `requirements.txt`.
3. Re-evaluate the native asset version, source, checksum, path, and offline load.
4. Run the complete offline suite, then the approved gated live comparison and intentional fixture refresh.
5. Deploy off and repeat shadow gates; restore the prior image/lock on regression.
