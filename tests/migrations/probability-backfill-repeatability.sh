#!/usr/bin/env sh
set -eu

container=$1
runner=$2

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
    SELECT source.id, '940000000000000101',
      'https://x.com/backfillrace/status/940000000000000101',
      'interrupted concurrent fixture', '2026-08-27 00:00:01+00'
    FROM source;
    INSERT INTO probability_backfill_replays (
      raw_post_id, extraction_schema_version, claimed_run_key, evaluation_time,
      claimed_at, lease_expires_at
    ) SELECT id, 'qwen-evidence-v1', 'interrupted-run', '2026-08-27 12:00:00+00',
      '2026-08-27 11:00:00+00', '2026-08-27 11:15:00+00'
    FROM raw_posts WHERE external_post_id = '940000000000000101';
    INSERT INTO probability_backfill_claim_attempts (
      raw_post_id, extraction_schema_version, run_key, evaluation_time,
      claimed_at, lease_expires_at
    ) SELECT id, 'qwen-evidence-v1', 'interrupted-run', '2026-08-27 12:00:00+00',
      '2026-08-27 11:00:00+00', '2026-08-27 11:15:00+00'
    FROM raw_posts WHERE external_post_id = '940000000000000101';" >/dev/null

"$runner" "$container"
"$runner" "$container"

leftovers=$(docker exec "$container" psql --username transfers --dbname transfers \
  --tuples-only --no-align --set ON_ERROR_STOP=1 --command "SELECT
    (SELECT count(*) FROM probability_backfill_claim_attempts attempt
      JOIN raw_posts post ON post.id = attempt.raw_post_id
      WHERE post.external_post_id LIKE '940000000000000%')
    + (SELECT count(*) FROM probability_backfill_replays replay
      JOIN raw_posts post ON post.id = replay.raw_post_id
      WHERE post.external_post_id LIKE '940000000000000%')
    + (SELECT count(*) FROM raw_posts WHERE external_post_id LIKE '940000000000000%')
    + (SELECT count(*) FROM source_accounts WHERE external_account_id = '940000000000000001');")
test "$leftovers" = "0"

echo "Probability backfill repeatability passed"
