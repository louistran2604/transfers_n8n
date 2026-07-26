# Supporting services

This Compose project runs PostgreSQL 16 for the football-transfer monitor. It exposes no host port; n8n reaches it only through the external `transfers_net` Docker network at `transfers-postgres:5432`.

## 1. Configure local credentials

Use the existing ignored `deploy/support/.env`. If it is missing, create it
locally with `POSTGRES_USER` and `POSTGRES_PASSWORD`; this repository
intentionally has no `.env.example`.

Use a long random password. Do not commit or print that file.

## 2. Start PostgreSQL

```bash
docker network create transfers_net
docker compose up -d transfers-postgres
docker compose ps
```

If the network already exists, Docker reports that fact; continue with the next command.

## 3. Apply migrations and run tests

```bash
docker compose --profile maintenance run --rm transfers-db-migrate
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql'
docker compose exec -T transfers-postgres \
  sh -c 'psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql'
```

The schema is initialized automatically only for a new database volume. Run the maintenance command after pulling future migrations.

## Connection settings for n8n

```text
Host: transfers-postgres
Port: 5432
Database: transfers_net
User: value of POSTGRES_USER
Password: value of POSTGRES_PASSWORD
SSL: disabled inside the private Docker network
```

## Stop safely

```bash
docker compose down
```

This stops containers but preserves the `transfers_postgres_data` volume. Do not use `docker compose down --volumes` unless you explicitly intend to delete all persisted transfer data.
