-------------------------------------------------------------------------------
-- prep-sqlserver.sql
--
-- Prepares SQL Server (RDS) for Change Data Capture:
--   1. Creates the target database
--   2. Enables CDC at the database level
--   3. Creates a dedicated CDC reader user
--   4. Configures CDC agent polling interval
--
-- After running this script, you must:
--   a) Create your application tables (see examples below)
--   b) Enable CDC on each table individually (see examples below)
--
-- Run with: sqlcmd -S <host>,1433 -U cdcadmin -P <password> -i prep-sqlserver.sql -C
-- Note: Uses RDS-specific procedures (msdb.dbo.rds_cdc_*) instead of sys.sp_cdc_*
--       because RDS master user does not have sysadmin privileges.
--
-- For custom database names, use sqlcmd variable substitution:
--   sqlcmd -v DB_NAME="mydb" -S <host>,1433 -U cdcadmin -P <password> -i prep-sqlserver.sql -C
-- Default: if DB_NAME not provided, uses 'pocdb'
-------------------------------------------------------------------------------

-- Database name (default: pocdb, override with -v DB_NAME="yourdb")
:setvar DB_NAME pocdb

USE [master];
GO

-- Create database if not exists
IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = '$(DB_NAME)')
BEGIN
    CREATE DATABASE [$(DB_NAME)];
    PRINT 'Created database [$(DB_NAME)]';
END
GO

USE [$(DB_NAME)];
GO

-------------------------------------------------------------------------------
-- 1. Enable CDC at database level
-------------------------------------------------------------------------------

IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = '$(DB_NAME)' AND is_cdc_enabled = 1)
BEGIN
    EXEC msdb.dbo.rds_cdc_enable_db '$(DB_NAME)';
    PRINT 'CDC enabled on database [$(DB_NAME)] (via RDS procedure)';
END
GO

-------------------------------------------------------------------------------
-- 2. Create CDC reader user
--    Used by JDBC Sink connectors for write access.
--    NOTE: Debezium source connectors use the admin user (cdcadmin/sa) because
--    RDS SQL Server does not allow orphaned user SID remapping. If the cdc_reader
--    login SID does not match the database user SID, authentication fails.
-------------------------------------------------------------------------------

-- IMPORTANT: Set a strong password in CDC_READER_PASSWORD before running!
-- Use sqlcmd variable substitution to pass the password securely:
--   sqlcmd -v CDC_PWD="<your-secure-password>" -i prep-sqlserver.sql
-- Then set CDC_READER_PASSWORD in .env for JDBC sink connectors.
-- Example (INSECURE — use a strong password):
--   sqlcmd -v CDC_PWD="MySecurePassword123!" -i prep-sqlserver.sql
IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'cdc_reader')
BEGIN
    CREATE LOGIN cdc_reader WITH PASSWORD = '$(CDC_PWD)';
    PRINT 'Created login cdc_reader';
END
GO

USE [$(DB_NAME)];
GO

IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'cdc_reader')
BEGIN
    CREATE USER cdc_reader FOR LOGIN cdc_reader;
    PRINT 'Created user cdc_reader in pocdb';
END
GO

-- Grant permissions required by Debezium
EXEC sp_addrolemember 'db_datareader', 'cdc_reader';
EXEC sp_addrolemember 'db_owner', 'cdc_reader';  -- Required for CDC access on RDS

PRINT 'Granted CDC permissions to cdc_reader';
GO

-------------------------------------------------------------------------------
-- 3. Configure CDC agent polling interval (seconds)
--    0 = continuous (no sleep between scans, ~50-150ms capture latency)
--    sys.sp_cdc_change_job works on RDS SQL Server without sysadmin.
--    Use 1 for dev/cost savings; 0 for production sub-second CDC.
-------------------------------------------------------------------------------

EXEC sys.sp_cdc_change_job
    @job_type = 'capture',
    @pollinginterval = 0,
    @maxtrans      = 5000,
    @maxscans      = 100;

PRINT 'CDC capture polling interval set to 0 (continuous)';
GO

-------------------------------------------------------------------------------
-- 4. Verify CDC setup
-------------------------------------------------------------------------------

PRINT '';
PRINT '=== CDC Infrastructure Verification ===';
PRINT 'Database CDC enabled: yes';
PRINT 'CDC reader user: created';
PRINT 'Polling interval: 0 (continuous)';
PRINT '';
PRINT 'Next steps:';
PRINT '  1. Create your application tables';
PRINT '  2. Enable CDC on each table (see examples below)';
GO

-------------------------------------------------------------------------------
-- EXAMPLES: Create tables and enable CDC on them
--
-- Adapt these patterns for your own tables. Key considerations:
--
--   * PK columns: Use BIGINT (not IDENTITY) for bi-directional CDC.
--     JDBC sink connectors insert explicit PK values from the source system,
--     which IDENTITY columns reject by default. BIGINT prevents exhaustion
--     on long-running workloads (INT overflows in hours at high throughput).
--
--   * No-PK tables: Debezium requires @supports_net_changes = 0.
--     Use ValueToKey SMT in the connector config to construct a key from
--     value fields for upsert on the sink side.
--
--   * PII columns: Mark with comments. Use MaskField SMT in the connector
--     config for in-flight masking.
--
--   * Loop prevention: Uses Kafka Headers (InsertHeader SMT + HasHeaderKey
--     predicate). No marker columns needed in table schemas.
-------------------------------------------------------------------------------

-- CUSTOMER RESPONSIBILITY:
-- These examples below show table schemas for different CDC scenarios.
-- UNCOMMENT and use as templates, OR create your own tables with similar patterns.
-- Replace dbo.accounts, dbo.transactions, dbo.audit_log with YOUR table names.
-- Then enable CDC on YOUR tables using the provided EXEC sys.sp_cdc_enable_table commands.
-- Update .env SQLSERVER_TABLE_INCLUDE_LIST to match your actual table names.

/*  -- Example 1: Table with PK + PII columns

IF OBJECT_ID('dbo.accounts', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.accounts (
        account_id      BIGINT        NOT NULL PRIMARY KEY,  -- BIGINT, not IDENTITY
        full_name       NVARCHAR(200) NOT NULL,
        email           NVARCHAR(255) NOT NULL,              -- PII: mask with MaskField SMT
        phone           NVARCHAR(20)  NULL,                  -- PII: mask with MaskField SMT
        status          VARCHAR(20)   NOT NULL DEFAULT 'active',
        created_at      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
    );
END
GO

-- Enable CDC on a PK table (supports net changes)
IF NOT EXISTS (
    SELECT 1 FROM cdc.change_tables
    WHERE source_object_id = OBJECT_ID('dbo.accounts')
)
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema  = N'dbo',
        @source_name    = N'accounts',
        @role_name      = N'cdc_reader',
        @supports_net_changes = 1;
    PRINT 'CDC enabled on dbo.accounts';
END
GO
*/

/*  -- Example 2: Table with PK (standard)

IF OBJECT_ID('dbo.transactions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.transactions (
        transaction_id  BIGINT        NOT NULL PRIMARY KEY,  -- BIGINT, not IDENTITY
        account_id      BIGINT        NOT NULL,
        transaction_date DATETIME2    NOT NULL DEFAULT SYSUTCDATETIME(),
        status          VARCHAR(20)   NOT NULL DEFAULT 'pending',
        amount          DECIMAL(12,2) NOT NULL DEFAULT 0.00,
        currency        CHAR(3)       NOT NULL DEFAULT 'USD',
        notes           NVARCHAR(MAX) NULL,
        created_at      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        updated_at      DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
    );
END
GO

-- Enable CDC (same pattern as above)
IF NOT EXISTS (
    SELECT 1 FROM cdc.change_tables
    WHERE source_object_id = OBJECT_ID('dbo.transactions')
)
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema  = N'dbo',
        @source_name    = N'transactions',
        @role_name      = N'cdc_reader',
        @supports_net_changes = 1;
    PRINT 'CDC enabled on dbo.transactions';
END
GO
*/

/*  -- Example 3: Table WITHOUT primary key (composite unique key for CDC upsert)

IF OBJECT_ID('dbo.audit_log', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.audit_log (
        event_timestamp DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME(),
        event_type      VARCHAR(50)   NOT NULL,
        source_type     VARCHAR(50)   NOT NULL,
        source_id       BIGINT        NOT NULL,
        payload         NVARCHAR(MAX) NULL,
        source_system   VARCHAR(50)   NOT NULL DEFAULT 'SQLSERVER',
        CONSTRAINT UQ_audit_log_key UNIQUE (event_timestamp, source_type, source_id)
    );
END
GO

-- Enable CDC on a no-PK table (no net changes support)
IF NOT EXISTS (
    SELECT 1 FROM cdc.change_tables
    WHERE source_object_id = OBJECT_ID('dbo.audit_log')
)
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema  = N'dbo',
        @source_name    = N'audit_log',
        @role_name      = N'cdc_reader',
        @supports_net_changes = 0;  -- Must be 0 for no-PK tables
    PRINT 'CDC enabled on dbo.audit_log';
END
GO
*/

/*  -- Verify CDC-enabled tables after enabling your tables:

SELECT
    t.name AS table_name,
    ct.capture_instance,
    ct.supports_net_changes
FROM cdc.change_tables ct
JOIN sys.tables t ON ct.source_object_id = t.object_id
ORDER BY t.name;
GO
*/
