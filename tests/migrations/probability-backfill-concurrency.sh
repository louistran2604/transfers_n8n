#!/usr/bin/env sh
set -eu

container=$1
temporary=$(mktemp -d)

cleanup_database() {
  docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
    --command "DELETE FROM probability_backfill_claim_attempts WHERE raw_post_id IN (
        SELECT id FROM raw_posts WHERE external_post_id LIKE '940000000000000%'
      );
      DELETE FROM probability_backfill_replays WHERE raw_post_id IN (
        SELECT id FROM raw_posts WHERE external_post_id LIKE '940000000000000%'
      );
      DELETE FROM raw_posts WHERE external_post_id LIKE '940000000000000%';
      DELETE FROM source_accounts WHERE external_account_id = '940000000000000001';"
}

cleanup() {
  cleanup_database >/dev/null 2>&1 || true
  rm -rf "$temporary"
}
trap cleanup EXIT INT TERM

cleanup_database >/dev/null

docker exec "$container" psql --username transfers --dbname transfers --set ON_ERROR_STOP=1 \
  --command "WITH source AS (
      INSERT INTO source_accounts (
        external_account_id, username, display_name, account_type, priority_rank,
        reliability_score, seed_reliability, publisher_group_key, source_kind
      ) VALUES ('940000000000000001', 'backfillrace', 'Backfill Race', 'individual', 2,
        0.8, 0.8, 'reporter:backfill-race', 'journalist')
      RETURNING id
    )
    INSERT INTO raw_posts (source_account_id, external_post_id, post_url, content, posted_at)
    SELECT source.id, (940000000000000100 + value)::text,
      'https://x.com/backfillrace/status/' || (940000000000000100 + value)::text,
      'concurrent backfill fixture',
      '2026-08-27 00:00:00+00'::timestamptz + value * interval '1 second'
    FROM source CROSS JOIN generate_series(1, 150) value;" >/dev/null

claim() {
  app_name=$1
  run_key=$2
  output=$3
  docker exec -e PGAPPNAME="$app_name" "$container" psql \
    --username transfers --dbname transfers --set ON_ERROR_STOP=1 --tuples-only --no-align \
    --command "SELECT raw_post_id FROM claim_probability_backfill(
      'shadow', '2026-08-27 12:00:00+00', '$run_key', 'qwen-evidence-v1', 100, interval '15 minutes'
    ) ORDER BY raw_post_id;" >"$output"
}

claim backfill-concurrency-a backfill-concurrency-a "$temporary/a.ids" &
a_pid=$!
claim backfill-concurrency-b backfill-concurrency-b "$temporary/b.ids" &
b_pid=$!
wait "$a_pid"
wait "$b_pid"

a_count=$(wc -l <"$temporary/a.ids")
b_count=$(wc -l <"$temporary/b.ids")
unique_count=$(cat "$temporary/a.ids" "$temporary/b.ids" | sort -u | wc -l)
overlap_count=$(comm -12 "$temporary/a.ids" "$temporary/b.ids" | wc -l)
echo "Probability backfill concurrent claim counts: a=$a_count b=$b_count unique=$unique_count overlap=$overlap_count"
test "$a_count" -gt 0
test "$b_count" -gt 0
test "$unique_count" = "150"
test "$overlap_count" = "0"

echo "Probability backfill concurrent claims passed"
