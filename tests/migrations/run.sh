#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
run_id="m7-migrations-$$"
main_container="transfers-${run_id}-main"
restore_container="transfers-${run_id}-restore"
main_volume="transfers_${run_id}_main"
restore_volume="transfers_${run_id}_restore"
temporary=$(mktemp -d)

cleanup() {
  docker rm -f "$main_container" "$restore_container" >/dev/null 2>&1 || true
  docker volume rm "$main_volume" "$restore_volume" >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

start_postgres() {
  container=$1
  volume=$2
  docker run -d \
    --name "$container" \
    --network none \
    -e POSTGRES_DB=transfers \
    -e POSTGRES_USER=transfers \
    -e POSTGRES_PASSWORD=transfers_test_password \
    -v "$volume:/var/lib/postgresql/data" \
    -v "$root_dir/database:/database:ro" \
    postgres:16 >/dev/null

  attempts=0
  until docker exec "$container" pg_isready \
    --username transfers --dbname transfers >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 30 ]; then
      docker logs "$container"
      echo "PostgreSQL did not become ready" >&2
      exit 1
    fi
    sleep 1
  done
}

psql_file() {
  container=$1
  database=$2
  file=$3
  docker exec "$container" psql \
    --username transfers \
    --dbname "$database" \
    --set ON_ERROR_STOP=1 \
    --file "$file"
}

initialize_001() {
  container=$1
  database=$2
  psql_file "$container" "$database" /database/migrations/001_initial_schema.sql
  docker exec "$container" psql \
    --username transfers \
    --dbname "$database" \
    --set ON_ERROR_STOP=1 \
    --command "CREATE TABLE app_schema_migrations (
      version text PRIMARY KEY,
      applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
    );
    INSERT INTO app_schema_migrations (version) VALUES ('001_initial_schema');"
}

start_postgres "$main_container" "$main_volume"
initialize_001 "$main_container" transfers

docker exec -i "$main_container" psql \
  --username transfers \
  --dbname transfers \
  --set ON_ERROR_STOP=1 <<'SQL'
INSERT INTO players (identity_key, display_name, normalized_name)
VALUES ('pre-002-player', 'Pre-002 Player', 'pre-002 player');

INSERT INTO digest_deliveries (
  idempotency_key,
  channel_key,
  window_started_at,
  window_ended_at
)
VALUES (
  'pre-002-delivery',
  'transfers',
  '2026-07-29 00:00:00+00',
  '2026-07-29 06:00:00+00'
);
SQL

docker exec "$main_container" pg_dump \
  --username transfers \
  --dbname transfers \
  --format custom \
  --file /tmp/pre-002.dump
docker cp "$main_container:/tmp/pre-002.dump" "$temporary/pre-002.dump" >/dev/null
backup_sha256=$(sha256sum "$temporary/pre-002.dump" | awk '{print $1}')
test -n "$backup_sha256"

psql_file "$main_container" transfers /database/migrate.sql
psql_file "$main_container" transfers /database/migrate.sql

docker exec "$main_container" createdb \
  --username transfers \
  --owner transfers \
  concurrent_fresh
(
  psql_file "$main_container" concurrent_fresh /database/migrate.sql
) >"$temporary/concurrent-1.log" 2>&1 &
first_pid=$!
(
  psql_file "$main_container" concurrent_fresh /database/migrate.sql
) >"$temporary/concurrent-2.log" 2>&1 &
second_pid=$!
first_status=0
second_status=0
wait "$first_pid" || first_status=$?
wait "$second_pid" || second_status=$?
if [ "$first_status" -ne 0 ] || [ "$second_status" -ne 0 ]; then
  cat "$temporary/concurrent-1.log" "$temporary/concurrent-2.log" >&2
  exit 1
fi

concurrent_versions=$(docker exec "$main_container" psql \
  --username transfers \
  --dbname concurrent_fresh \
  --tuples-only \
  --no-align \
  --command "SELECT count(*) FROM app_schema_migrations;")
test "$concurrent_versions" = "6"

for test_file in \
  /database/tests/001_dedup_restart_safety.sql \
  /database/tests/002_workflow_safety.sql \
  /database/tests/003_soccerdata_enrichment.sql \
  /database/tests/004_enrichment_rollback_compatibility.sql \
  /database/tests/005_transfer_probability.sql \
  /database/tests/006_probability_v1_engine.sql \
  /database/tests/007_probability_v1_normalization.sql \
  /database/tests/011_probability_backfill.sql; do
  psql_file "$main_container" transfers "$test_file"
done

"$root_dir/tests/migrations/probability-backfill-concurrency.sh" "$main_container"
"$root_dir/tests/migrations/probability-v1-concurrency.sh" "$main_container"

node "$root_dir/tests/migrations/generated-enrichment-persistence.mjs" \
  "$temporary/generated-enrichment-persistence.sql"
docker cp "$temporary/generated-enrichment-persistence.sql" \
  "$main_container:/tmp/generated-enrichment-persistence.sql" >/dev/null
psql_file "$main_container" transfers /tmp/generated-enrichment-persistence.sql

start_postgres "$restore_container" "$restore_volume"
docker cp "$temporary/pre-002.dump" "$restore_container:/tmp/pre-002.dump" >/dev/null
docker exec "$restore_container" pg_restore \
  --username transfers \
  --dbname transfers \
  --exit-on-error \
  /tmp/pre-002.dump

restored_rows=$(docker exec "$restore_container" psql \
  --username transfers \
  --dbname transfers \
  --tuples-only \
  --no-align \
  --command "SELECT
    (SELECT count(*) FROM players WHERE identity_key = 'pre-002-player')
    + (SELECT count(*) FROM digest_deliveries WHERE idempotency_key = 'pre-002-delivery');")
test "$restored_rows" = "2"

psql_file "$restore_container" transfers /database/migrate.sql
psql_file "$restore_container" transfers /database/tests/001_dedup_restart_safety.sql
psql_file "$restore_container" transfers /database/tests/002_workflow_safety.sql

echo "Migration suite passed: pre-002 backup sha256=$backup_sha256"
