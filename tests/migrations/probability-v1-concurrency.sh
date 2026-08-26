#!/usr/bin/env sh
set -eu

container=$1
temporary=$(mktemp -d)

cleanup() {
  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name IN ('prob-v1-lock-controller', 'prob-v1-concurrency-a', 'prob-v1-concurrency-b')
        AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/010_probability_v1_concurrency_cleanup.sql >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --file /database/tests/008_probability_v1_concurrency_setup.sql

docker exec -e PGAPPNAME=prob-v1-lock-controller "$container" psql \
  --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --command "SELECT pg_advisory_lock(930005); SELECT pg_sleep(30);" \
  >"$temporary/controller.log" 2>&1 &
controller_pid=$!

attempts=0
until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'prob-v1-lock-controller' AND wait_event = 'PgSleep';" | grep -q '^1$'; do
  attempts=$((attempts + 1))
  test "$attempts" -lt 50
  sleep 0.1
done

docker exec -e PGAPPNAME=prob-v1-concurrency-a "$container" psql \
  --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --command "SET deadlock_timeout = '100ms';
    SELECT apply_probability_v1_shadow(report_id, payload)
    FROM probability_v1_concurrency_fixture WHERE label = 'alpha';" \
  >"$temporary/a.log" 2>&1 &
a_pid=$!

attempts=0
until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'prob-v1-concurrency-a' AND wait_event = 'advisory';" | grep -q '^1$'; do
  attempts=$((attempts + 1))
  test "$attempts" -lt 50
  sleep 0.1
done

docker exec -e PGAPPNAME=prob-v1-concurrency-b "$container" psql \
  --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --command "SET deadlock_timeout = '100ms';
    SELECT apply_probability_v1_shadow(report_id, payload)
    FROM probability_v1_concurrency_fixture WHERE label = 'beta';" \
  >"$temporary/b.log" 2>&1 &
b_pid=$!

attempts=0
until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'prob-v1-concurrency-b' AND wait_event_type = 'Lock';" | grep -q '^1$'; do
  attempts=$((attempts + 1))
  test "$attempts" -lt 50
  sleep 0.1
done

docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
  --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name = 'prob-v1-lock-controller';" >/dev/null
wait "$controller_pid" || true

a_status=0
b_status=0
wait "$a_pid" || a_status=$?
wait "$b_pid" || b_status=$?
if [ "$a_status" -ne 0 ] || [ "$b_status" -ne 0 ]; then
  cat "$temporary/a.log" "$temporary/b.log" >&2
  exit 1
fi

docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --file /database/tests/009_probability_v1_concurrency_assert.sql

docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --file /database/tests/010_probability_v1_concurrency_cleanup.sql
