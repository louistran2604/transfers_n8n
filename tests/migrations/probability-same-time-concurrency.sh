#!/usr/bin/env sh
set -eu

container=$1
temporary=$(mktemp -d)
cleanup() {
  docker exec "$container" psql -U transfers -d transfers -At -c "SELECT pg_terminate_backend(pid)
    FROM pg_stat_activity WHERE application_name IN ('same-time-controller','same-time-a','same-time-b')
      AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$container" psql -U transfers -d transfers -v ON_ERROR_STOP=1 \
    -f /database/tests/027_probability_same_time_cleanup.sql >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

docker exec "$container" psql -U transfers -d transfers -v ON_ERROR_STOP=1 \
  -f /database/tests/025_probability_same_time_setup.sql >/dev/null
docker exec -e PGAPPNAME=same-time-controller "$container" psql -U transfers -d transfers \
  -v ON_ERROR_STOP=1 -c "SELECT pg_advisory_lock(950009); SELECT pg_sleep(30);" \
  >"$temporary/controller.log" 2>&1 &
controller_pid=$!
attempts=0
until docker exec "$container" psql -U transfers -d transfers -At -c "SELECT count(*)
  FROM pg_stat_activity WHERE application_name='same-time-controller' AND wait_event='PgSleep';" | grep -q '^1$'; do
  attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
done

docker exec -e PGAPPNAME=same-time-a "$container" psql -U transfers -d transfers -v ON_ERROR_STOP=1 \
  -c "SELECT probability_v1_settle_authoritative_claims(transfer_case_id, '2026-04-03 00:00+00')
    FROM probability_same_time_fixture WHERE label='1';" >"$temporary/a.log" 2>&1 &
a_pid=$!
attempts=0
until docker exec "$container" psql -U transfers -d transfers -At -c "SELECT count(*)
  FROM pg_stat_activity WHERE application_name='same-time-a' AND wait_event='advisory';" | grep -q '^1$'; do
  attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
done

docker exec -e PGAPPNAME=same-time-b "$container" psql -U transfers -d transfers -v ON_ERROR_STOP=1 \
  -c "SELECT probability_v1_settle_authoritative_claims(transfer_case_id, '2026-04-03 00:00+00')
    FROM probability_same_time_fixture WHERE label='2';" >"$temporary/b.log" 2>&1 &
b_pid=$!
attempts=0
until docker exec "$container" psql -U transfers -d transfers -At -c "SELECT count(*)
  FROM pg_stat_activity WHERE application_name='same-time-b' AND wait_event_type='Lock';" | grep -q '^1$'; do
  attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
done

docker exec "$container" psql -U transfers -d transfers -At -c "SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity WHERE application_name='same-time-controller';" >/dev/null
wait "$controller_pid" || true
a_status=0; b_status=0
wait "$a_pid" || a_status=$?
wait "$b_pid" || b_status=$?
if [ "$a_status" -ne 0 ] || [ "$b_status" -ne 0 ]; then
  cat "$temporary/a.log" "$temporary/b.log" >&2; exit 1
fi
docker exec "$container" psql -U transfers -d transfers -v ON_ERROR_STOP=1 \
  -f /database/tests/026_probability_same_time_assert.sql
echo "same-time shared-reporter settlement concurrency passed"
