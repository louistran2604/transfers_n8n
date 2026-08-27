#!/usr/bin/env sh
set -eu

container=$1
temporary=$(mktemp -d)

cleanup() {
  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name IN ('prob-stale-controller', 'prob-stale-a', 'prob-stale-b')
        AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/014_probability_stale_concurrency_cleanup.sql >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

run_once() {
  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/013_probability_stale_concurrency_setup.sql

  docker exec -e PGAPPNAME=prob-stale-controller "$container" psql \
    --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --command "SELECT pg_advisory_lock(940007); SELECT pg_sleep(30);" \
    >"$temporary/controller.log" 2>&1 &
  controller_pid=$!

  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'prob-stale-controller' AND wait_event = 'PgSleep';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done

  docker exec -e PGAPPNAME=prob-stale-a "$container" psql --username transfers --dbname transfers \
    --set ON_ERROR_STOP=1 --command "SELECT recompute_stale_probability_v1_cases(
      'shadow', '2026-08-08 12:00:00+00', 5);" >"$temporary/a.log" 2>&1 &
  a_pid=$!
  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'prob-stale-a' AND wait_event = 'advisory';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done

  docker exec -e PGAPPNAME=prob-stale-b "$container" psql --username transfers --dbname transfers \
    --set ON_ERROR_STOP=1 --command "SELECT recompute_stale_probability_v1_cases(
      'shadow', '2026-08-08 12:00:00+00', 5);" >"$temporary/b.log" 2>&1 &
  b_pid=$!
  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'prob-stale-b' AND wait_event_type = 'Lock';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done

  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name = 'prob-stale-controller';" >/dev/null
  wait "$controller_pid" || true
  a_status=0; b_status=0
  wait "$a_pid" || a_status=$?
  wait "$b_pid" || b_status=$?
  if [ "$a_status" -ne 0 ] || [ "$b_status" -ne 0 ]; then
    cat "$temporary/a.log" "$temporary/b.log" >&2; exit 1
  fi

  result=$(docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) || ':' || count(DISTINCT transfer_case_id) || ':' || count(DISTINCT backend_pid)
      FROM probability_stale_concurrency_audit;")
  test "$result" = "10:10:2"
  duplicate_count=$(docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM (SELECT transfer_case_id FROM probability_stale_concurrency_audit
      GROUP BY transfer_case_id HAVING count(*) > 1) duplicate;")
  test "$duplicate_count" = "0"

  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/014_probability_stale_concurrency_cleanup.sql
}

run_once
run_once
echo "probability stale concurrency test passed twice"
