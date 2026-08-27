#!/usr/bin/env sh
set -eu

container=$1
database=probability_lifecycle_upgrade

docker exec "$container" dropdb --username transfers --if-exists "$database"
docker exec "$container" createdb --username transfers --owner transfers "$database"

psql_file() {
  docker exec "$container" psql --username transfers --dbname "$database" \
    --set ON_ERROR_STOP=1 --file "$1"
}

psql_file /database/migrations/001_initial_schema.sql
docker exec "$container" psql --username transfers --dbname "$database" --set ON_ERROR_STOP=1 \
  --command "CREATE TABLE app_schema_migrations (
    version text PRIMARY KEY,
    applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
  ); INSERT INTO app_schema_migrations (version) VALUES ('001_initial_schema');"

for migration in \
  002_soccerdata_enrichment \
  003_transfer_probability \
  004_probability_v1_engine \
  005_probability_v1_normalization \
  006_probability_backfill; do
  psql_file "/database/migrations/$migration.sql"
  docker exec "$container" psql --username transfers --dbname "$database" --set ON_ERROR_STOP=1 \
    --command "INSERT INTO app_schema_migrations (version) VALUES ('$migration');"
done

psql_file /database/tests/015_probability_lifecycle_upgrade_setup.sql
psql_file /database/migrations/007_probability_active_digest.sql
docker exec "$container" psql --username transfers --dbname "$database" --set ON_ERROR_STOP=1 \
  --command "INSERT INTO app_schema_migrations (version) VALUES ('007_probability_active_digest');"
psql_file /database/tests/016_probability_lifecycle_upgrade_assert.sql

docker exec "$container" dropdb --username transfers "$database"
