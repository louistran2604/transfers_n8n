\set ON_ERROR_STOP on

SELECT pg_advisory_lock(hashtext('transfers_net_schema_migrations'));

CREATE TABLE IF NOT EXISTS app_schema_migrations (
  version text PRIMARY KEY,
  applied_at timestamptz NOT NULL DEFAULT CURRENT_TIMESTAMP
);

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

SELECT CASE
  WHEN EXISTS (
    SELECT 1
    FROM app_schema_migrations
    WHERE version = '002_soccerdata_enrichment'
  ) THEN 'false'
  ELSE 'true'
END AS migration_002_pending \gset

\if :migration_002_pending
  BEGIN;
  \i /database/migrations/002_soccerdata_enrichment.sql
  INSERT INTO app_schema_migrations (version) VALUES ('002_soccerdata_enrichment');
  COMMIT;
\endif

SELECT CASE
  WHEN EXISTS (
    SELECT 1
    FROM app_schema_migrations
    WHERE version = '003_transfer_probability'
  ) THEN 'false'
  ELSE 'true'
END AS migration_003_pending \gset

\if :migration_003_pending
  BEGIN;
  \i /database/migrations/003_transfer_probability.sql
  INSERT INTO app_schema_migrations (version) VALUES ('003_transfer_probability');
  COMMIT;
\endif

SELECT pg_advisory_unlock(hashtext('transfers_net_schema_migrations'));
