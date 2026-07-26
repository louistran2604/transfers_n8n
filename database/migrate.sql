\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS app_schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

SELECT pg_advisory_lock(hashtext('transfers_net_schema_migrations'));

SELECT CASE
  WHEN EXISTS (
    SELECT 1
    FROM app_schema_migrations
    WHERE version = '001_initial_schema'
  ) THEN 'false'
  ELSE 'true'
END AS migration_001_pending \gset

\if :migration_001_pending
  \i /database/migrations/001_initial_schema.sql
  INSERT INTO app_schema_migrations (version) VALUES ('001_initial_schema');
\endif

SELECT pg_advisory_unlock(hashtext('transfers_net_schema_migrations'));
