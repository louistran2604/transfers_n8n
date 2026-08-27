#!/usr/bin/env sh
set -eu

container=$1
temporary=$(mktemp -d)

cleanup() {
  docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
      WHERE application_name IN ('fee-context-controller', 'fee-context-mutator',
        'fee-context-projection-a', 'fee-context-projection-b')
        AND pid <> pg_backend_pid();" >/dev/null 2>&1 || true
  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --file /database/tests/018_fee_context_concurrency_cleanup.sql >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --file /database/tests/017_fee_context_concurrency_setup.sql

docker exec -e PGAPPNAME=fee-context-controller "$container" psql \
  --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --command "SELECT pg_advisory_lock(960008); SELECT pg_sleep(30);" \
  >"$temporary/controller.log" 2>&1 &
controller_pid=$!

attempts=0
until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'fee-context-controller' AND wait_event = 'PgSleep';" | grep -q '^1$'; do
  attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
done

docker exec -e PGAPPNAME=fee-context-mutator "$container" psql \
  --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --command "SELECT fee_context_concurrency_mutate();" \
  >"$temporary/mutator.log" 2>&1 &
mutator_pid=$!

attempts=0
until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
  --command "SELECT count(*) FROM pg_stat_activity
    WHERE application_name = 'fee-context-mutator' AND wait_event = 'advisory';" | grep -q '^1$'; do
  attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
done

for worker in a b; do
  docker exec -e PGAPPNAME="fee-context-projection-$worker" "$container" psql \
    --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --command "SELECT project_transfer_fee_context('2099-01-01 12:00:00+00',
      '2099-01-01 00:00:00+00', '2099-01-02 00:00:00+00');" \
    >"$temporary/$worker.log" 2>&1 &
  eval "${worker}_pid=$!"
  attempts=0
  until docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
    --command "SELECT count(*) FROM pg_stat_activity
      WHERE application_name = 'fee-context-projection-$worker'
        AND wait_event_type = 'Lock';" | grep -q '^1$'; do
    attempts=$((attempts + 1)); test "$attempts" -lt 50; sleep 0.1
  done
done

docker exec "$container" psql --username transfers --dbname transfers --tuples-only --no-align \
  --command "SELECT pg_terminate_backend(pid) FROM pg_stat_activity
    WHERE application_name = 'fee-context-controller';" >/dev/null
wait "$controller_pid" || true

mutator_status=0; a_status=0; b_status=0
wait "$mutator_pid" || mutator_status=$?
wait "$a_pid" || a_status=$?
wait "$b_pid" || b_status=$?
if [ "$mutator_status" -ne 0 ] || [ "$a_status" -ne 0 ] || [ "$b_status" -ne 0 ]; then
  cat "$temporary/mutator.log" "$temporary/a.log" "$temporary/b.log" >&2
  exit 1
fi

result=$(docker exec "$container" psql --username transfers --dbname transfers \
  --tuples-only --no-align --command "SELECT string_agg(fixture.label || ':' ||
    revision_count || ':' || latest_classification || ':' || has_fee_context, ',' ORDER BY fixture.label)
  FROM fee_context_concurrency_fixture fixture
  CROSS JOIN LATERAL (SELECT count(*) AS revision_count,
    (array_agg(revision.snapshot->>'classification' ORDER BY revision.revision_number DESC))[1] AS latest_classification,
    (array_agg((revision.snapshot ? 'fee_context')::text ORDER BY revision.revision_number DESC))[1] AS has_fee_context
    FROM transfer_report_revisions revision WHERE revision.transfer_report_id = fixture.report_id) state;")
test "$result" = "material:3:confirmed:true,pending:1:rumor:false,projection:2:rumor:true"

pending=$(docker exec "$container" psql --username transfers --dbname transfers \
  --tuples-only --no-align --command "SELECT request_payload::text || ':' || count(item.id)
  FROM digest_deliveries delivery JOIN digest_items item ON item.digest_delivery_id = delivery.id
  WHERE delivery.idempotency_key = 'fee-concurrency-pending' GROUP BY delivery.request_payload;")
test "$pending" = '{"frozen": "exact"}:1'

docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --file /database/tests/018_fee_context_concurrency_cleanup.sql

echo "fee-context concurrency test passed"
