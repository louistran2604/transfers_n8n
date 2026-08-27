#!/usr/bin/env sh
set -eu

container=$1
temporary=$(mktemp -d)

cleanup() {
  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name IN ('prob-settlement-controller-a', 'prob-settlement-controller-b',
        'prob-settlement-reserve-a', 'prob-settlement-reserve-b',
        'prob-settlement-a', 'prob-settlement-b')
        AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/023_probability_settlement_concurrency_cleanup.sql >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

run_once() {
  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/022_probability_settlement_concurrency_setup.sql >/dev/null

  docker exec -e PGAPPNAME=prob-settlement-controller-a "$container" psql \
    --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --command "SELECT pg_advisory_lock(940009); SELECT pg_sleep(30);" \
    >"$temporary/controller-a.log" 2>&1 &
  controller_a_pid=$!
  docker exec -e PGAPPNAME=prob-settlement-controller-b "$container" psql \
    --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --command "SELECT pg_advisory_lock(940010); SELECT pg_sleep(30);" \
    >"$temporary/controller-b.log" 2>&1 &
  controller_b_pid=$!
  docker exec -e PGAPPNAME=prob-settlement-reserve-a "$container" psql \
    --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --command "BEGIN; SELECT id FROM transfer_cases
      WHERE case_key IN ('settlement-lock-5|2026-H1', 'settlement-lock-6|2026-H1')
      ORDER BY id FOR UPDATE; SELECT pg_sleep(30);" \
    >"$temporary/reserve-a.log" 2>&1 &
  reserve_a_pid=$!
  docker exec -e PGAPPNAME=prob-settlement-reserve-b "$container" psql \
    --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --command "BEGIN; SELECT id FROM transfer_cases
      WHERE case_key IN ('settlement-lock-7|2026-H1', 'settlement-lock-8|2026-H1')
      ORDER BY id FOR UPDATE; SELECT pg_sleep(30);" \
    >"$temporary/reserve-b.log" 2>&1 &
  reserve_b_pid=$!
  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name IN ('prob-settlement-controller-a', 'prob-settlement-controller-b',
        'prob-settlement-reserve-a', 'prob-settlement-reserve-b')
        AND wait_event = 'PgSleep';" | grep -q '^4$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done

  docker exec -e PGAPPNAME=prob-settlement-a "$container" psql --username transfers --dbname transfers \
    --set ON_ERROR_STOP=1 --command "SELECT settle_expired_probability_v1_cases(
      'shadow', '2026-07-15 00:00:00+00', 2);" >"$temporary/a.log" 2>&1 &
  a_pid=$!
  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'prob-settlement-a' AND wait_event = 'advisory';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done

  docker exec -e PGAPPNAME=prob-settlement-b "$container" psql --username transfers --dbname transfers \
    --set ON_ERROR_STOP=1 --command "SELECT settle_expired_probability_v1_cases(
      'shadow', '2026-07-15 00:00:00+00', 2);" >"$temporary/b.log" 2>&1 &
  b_pid=$!
  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'prob-settlement-b' AND wait_event_type = 'Lock';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done

  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name IN ('prob-settlement-reserve-a', 'prob-settlement-controller-a');" >/dev/null
  wait "$reserve_a_pid" || true
  wait "$controller_a_pid" || true

  attempts=0
  until ! kill -0 "$a_pid" 2>/dev/null || docker exec "$container" psql \
    --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'prob-settlement-a' AND wait_event_type = 'Lock';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done

  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name = 'prob-settlement-reserve-b';" >/dev/null
  wait "$reserve_b_pid" || true
  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'prob-settlement-b' AND wait_event = 'advisory';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done
  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name = 'prob-settlement-controller-b';" >/dev/null
  wait "$controller_b_pid" || true
  a_status=0; b_status=0
  wait "$a_pid" || a_status=$?
  wait "$b_pid" || b_status=$?
  if [ "$a_status" -ne 0 ] || [ "$b_status" -ne 0 ]; then
    cat "$temporary/a.log" "$temporary/b.log" >&2
    exit 1
  fi

  result=$(docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT
      (SELECT count(*) FROM probability_settlement_concurrency_audit) || ':' ||
      (SELECT count(DISTINCT transfer_case_id) FROM probability_settlement_concurrency_audit) || ':' ||
      (SELECT count(DISTINCT backend_pid) FROM probability_settlement_concurrency_audit) || ':' ||
      (SELECT min(case_count) FROM (
        SELECT count(*) AS case_count FROM probability_settlement_concurrency_audit
        GROUP BY backend_pid) participant) || ':' ||
      (SELECT max(case_count) FROM (
        SELECT count(*) AS case_count FROM probability_settlement_concurrency_audit
        GROUP BY backend_pid) participant) || ':' ||
      (SELECT count(*) FROM source_claim_outcomes outcome
        JOIN transfer_cases transfer_case ON transfer_case.id = outcome.transfer_case_id
        WHERE transfer_case.case_key LIKE 'settlement-lock-%'
          AND outcome.settlement_outcome = 'failure') || ':' ||
      (SELECT count(*) FROM source_claim_outcomes outcome
        JOIN transfer_cases transfer_case ON transfer_case.id = outcome.transfer_case_id
        WHERE transfer_case.case_key LIKE 'settlement-lock-%'
          AND outcome.settlement_outcome IS NULL);")
  test "$result" = "8:8:2:4:4:8:0" || {
    echo "unexpected settlement audit result: $result" >&2
    exit 1
  }

  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/023_probability_settlement_concurrency_cleanup.sql >/dev/null
}

run_once
run_once
echo "probability settlement concurrency test passed twice"
