-------------------------------------------------------------------------------
-- prep-aurora.sql
--
-- Prepares Aurora PostgreSQL (RDS) for Change Data Capture:
--   1. Verify logical replication is enabled
--   2. Create a dedicated CDC reader user with replication role
--   3. (After you create tables) Create publication for CDC tables
--   4. Create replication slot for Debezium
--
-- After running this script, you must:
--   a) Create your application tables (see examples below)
--   b) Create a publication covering those tables (see examples below)
--
-- Prerequisites:
--   - rds.logical_replication = 1 in the cluster parameter group
--   - Cluster rebooted after parameter change
--
-- For custom database names, connect to that database and run this script:
--   psql -h <aurora-endpoint> -p 5432 -U cdcadmin -d yourdb -f prep-aurora.sql
--
-- The database name is determined by the -d flag above.
-- No database variable needed in this script (unlike SQL Server).
-- Update AURORA_DATABASE in .env to match the -d flag you use.
-------------------------------------------------------------------------------

-- 1. Verify logical replication is enabled
DO $$
BEGIN
    IF current_setting('rds.logical_replication') != 'on' THEN
        RAISE EXCEPTION 'rds.logical_replication is NOT enabled. Set it to 1 in the cluster parameter group and reboot.';
    ELSE
        RAISE NOTICE 'rds.logical_replication = on ✓';
    END IF;
END
$$;

-- Also check wal_level
DO $$
BEGIN
    IF current_setting('wal_level') != 'logical' THEN
        RAISE WARNING 'wal_level is %, expected logical. This usually resolves after reboot with rds.logical_replication=1.', current_setting('wal_level');
    ELSE
        RAISE NOTICE 'wal_level = logical ✓';
    END IF;
END
$$;

-------------------------------------------------------------------------------
-- 2. Create CDC reader user with replication role
--    NOTE: On RDS Aurora, only the admin user (rds_superuser) can have REPLICATION.
--    Debezium source connectors must use the admin user (AURORA_USER) for CDC.
--    The cdc_reader role is used by JDBC Sink connectors for read/write access.
--    The REPLICATION grant below may fail on RDS — this is expected.
-------------------------------------------------------------------------------

-- Use psql variable substitution to pass the password securely:
--   psql -v cdc_password="<your-secure-password>" -f prep-aurora.sql
-- Example (INSECURE — use a strong password):
--   psql -v cdc_password="MySecurePassword123!" -f prep-aurora.sql
DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'cdc_reader') THEN
        CREATE ROLE cdc_reader WITH LOGIN PASSWORD :'cdc_password' REPLICATION;
        RAISE NOTICE 'Created role cdc_reader with REPLICATION';
    ELSE
        ALTER ROLE cdc_reader WITH REPLICATION;
        RAISE NOTICE 'Role cdc_reader already exists, ensured REPLICATION privilege';
    END IF;
END
$$;

-- Grant schema permissions (tables created later will inherit via DEFAULT PRIVILEGES)
GRANT USAGE ON SCHEMA public TO cdc_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO cdc_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO cdc_reader;

-- For JDBC Sink connector (needs write access + CREATE for auto-create)
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO cdc_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT INSERT, UPDATE, DELETE ON TABLES TO cdc_reader;
GRANT CREATE ON SCHEMA public TO cdc_reader;

-- Sequence permissions (for SERIAL columns)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO cdc_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO cdc_reader;

-------------------------------------------------------------------------------
-- 3. Create replication slot
--    Note: Debezium can auto-create this, but we create it explicitly to
--    ensure it exists before connector deployment.
-------------------------------------------------------------------------------

SELECT pg_create_logical_replication_slot('debezium_cdc', 'pgoutput')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_replication_slots WHERE slot_name = 'debezium_cdc'
);

-------------------------------------------------------------------------------
-- 4. Verify setup
-------------------------------------------------------------------------------

\echo ''
\echo '=== Aurora CDC Infrastructure Verification ==='

\echo ''
\echo 'Replication slots:'
SELECT slot_name, plugin, slot_type, active
FROM pg_replication_slots;

\echo ''
\echo 'CDC reader role:'
SELECT rolname, rolcanlogin, rolreplication
FROM pg_roles
WHERE rolname = 'cdc_reader';

\echo ''
\echo 'Aurora CDC infrastructure ready.'
\echo ''
\echo 'Next steps:'
\echo '  1. Create your application tables'
\echo '  2. Create a publication covering those tables (see examples in this file)'
\echo '  3. Grant permissions: GRANT SELECT, INSERT, UPDATE, DELETE ON <table> TO cdc_reader;'

-------------------------------------------------------------------------------
-- EXAMPLES: Create tables and publication
--
-- Adapt these patterns for your own tables. Key considerations:
--
--   * PK columns: Use BIGINT (not SERIAL/auto-increment) for bi-directional
--     CDC where explicit PK values arrive from the source system. BIGINT
--     prevents exhaustion on long-running workloads (INT overflows in hours
--     at high throughput).
--
--   * No-PK tables: Add a composite UNIQUE constraint on columns that
--     logically identify a row. Use ValueToKey SMT in the connector config.
--
--   * PII columns: Mark with comments. Use MaskField SMT in the connector
--     config for in-flight masking.
--
--   * Loop prevention: Only add tables to the publication that should replicate.
--     Tables not in the publication are not captured by Debezium.
--
--   * auto.create=true on JDBC Sink will auto-create tables, but explicit
--     creation gives you control over exact types and constraints.
-------------------------------------------------------------------------------

-- CUSTOMER RESPONSIBILITY:
-- These examples below show table schemas for different CDC scenarios.
-- UNCOMMENT and use as templates, OR create your own tables with similar patterns.
-- Replace public.accounts, public.transactions, public.audit_log with YOUR table names.
-- Then create a publication covering YOUR tables (see examples below).
-- No .env changes needed — Debezium auto-captures all tables in the publication.

/*  -- Example 1: Table with PK + PII columns

CREATE TABLE IF NOT EXISTS public.accounts (
    account_id      BIGINT          PRIMARY KEY,   -- BIGINT for bi-directional CDC (avoids INT exhaustion)
    full_name       VARCHAR(200)    NOT NULL,
    email           VARCHAR(255)    NOT NULL,       -- PII: mask with MaskField SMT
    phone           VARCHAR(20),                    -- PII: mask with MaskField SMT
    status          VARCHAR(20)     NOT NULL DEFAULT 'active',
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
*/

/*  -- Example 2: Table with PK (standard)

CREATE TABLE IF NOT EXISTS public.transactions (
    transaction_id  BIGINT          PRIMARY KEY,   -- BIGINT for bi-directional CDC (avoids INT exhaustion)
    account_id      BIGINT          NOT NULL,
    transaction_date TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
    status          VARCHAR(20)     NOT NULL DEFAULT 'pending',
    amount          NUMERIC(12,2)   NOT NULL DEFAULT 0.00,
    currency        CHAR(3)         NOT NULL DEFAULT 'USD',
    notes           TEXT,
    created_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ     NOT NULL DEFAULT NOW()
);
*/

/*  -- Example 3: Table WITHOUT primary key (composite unique key for CDC upsert)

CREATE TABLE IF NOT EXISTS public.audit_log (
    event_timestamp TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
    event_type      VARCHAR(50)     NOT NULL,
    source_type     VARCHAR(50)     NOT NULL,
    source_id       BIGINT          NOT NULL,
    payload         TEXT,
    source_system   VARCHAR(50)     NOT NULL DEFAULT 'AURORA',
    CONSTRAINT uq_audit_log_key UNIQUE (event_timestamp, source_type, source_id)
);
*/

/*  -- Create publication covering your CDC tables:

DO $$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname = 'cdc_publication') THEN
        CREATE PUBLICATION cdc_publication FOR TABLE
            public.accounts,
            public.transactions,
            public.audit_log;
        RAISE NOTICE 'Created publication cdc_publication';
    ELSE
        RAISE NOTICE 'Publication cdc_publication already exists';
    END IF;
END
$$;

-- Grant table permissions to cdc_reader:
GRANT SELECT, INSERT, UPDATE, DELETE ON public.accounts TO cdc_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.transactions TO cdc_reader;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.audit_log TO cdc_reader;
*/

/*  -- Verify publication after creating it:

SELECT pubname, puballtables FROM pg_publication;
SELECT tablename FROM pg_publication_tables WHERE pubname = 'cdc_publication';
*/
