#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
compose_file="$root_dir/tests/e2e/compose.yaml"

cleanup() {
  docker compose -f "$compose_file" down --volumes --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

docker compose -f "$compose_file" up -d --wait postgres mock-services
docker compose -f "$compose_file" exec -T postgres psql --username transfers_e2e --dbname transfers_e2e --set ON_ERROR_STOP=1 --file /database/tests/001_dedup_restart_safety.sql
docker compose -f "$compose_file" exec -T postgres psql --username transfers_e2e --dbname transfers_e2e --set ON_ERROR_STOP=1 --file /database/tests/002_workflow_safety.sql
docker compose -f "$compose_file" run --rm --no-deps n8n import:workflow --input=/workflows/football-transfer-monitor-errors.json
docker compose -f "$compose_file" run --rm --no-deps n8n import:workflow --input=/workflows/football-transfer-monitor.json
docker compose -f "$compose_file" up -d --wait n8n
node "$root_dir/tests/e2e/scenario.mjs"
