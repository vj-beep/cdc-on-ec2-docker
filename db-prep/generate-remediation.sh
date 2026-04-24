#!/bin/bash
# ============================================================
# Generate CDC Remediation Scripts
# ============================================================
# Connects to SQL Server and Aurora using credentials from .env,
# inspects current state, and generates targeted, idempotent SQL
# remediation scripts for any missing CDC prerequisites.
#
# Output:
#   db-prep/remediation-sqlserver.sql  (if SQL Server issues found)
#   db-prep/remediation-aurora.sql     (if Aurora issues found)
#
# Requires: sqlcmd, psql, .env with DB credentials
#
# Usage: ./db-prep/generate-remediation.sh
# ============================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

ENV_FILE="$REPO_DIR/.env"
OUTPUT_DIR="$REPO_DIR/db-prep"

# --- Color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET} $1"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $1"; }
action()  { echo -e "  ${YELLOW}+${RESET} $1"; }
err()     { echo -e "  ${RED}✗${RESET} $1"; }

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}ERROR: .env not found. Run 'cp .env.template .env' and fill in values first.${RESET}"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  CDC Remediation Script Generator${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

# ============================================================
# SQL Server Remediation
# ============================================================

generate_sqlserver() {
    local out="$OUTPUT_DIR/remediation-sqlserver.sql"
    local needs_remediation=false

    echo ""
    info "Connecting to SQL Server (${SQLSERVER_HOST})..."

    if ! command -v sqlcmd &>/dev/null; then
        err "sqlcmd not installed — skipping SQL Server"
        return
    fi

    SQLCMD_BASE="sqlcmd -S ${SQLSERVER_HOST},${SQLSERVER_PORT} -U ${SQLSERVER_USER} -C -l 10 -h -1 -W"
    export SQLCMDPASSWORD="${SQLSERVER_PASSWORD}"

    if ! $SQLCMD_BASE -Q "SELECT 1" &>/dev/null; then
        err "Cannot connect to SQL Server — check SQLSERVER_HOST/USER/PASSWORD in .env"
        unset SQLCMDPASSWORD
        return
    fi
    ok "Connected to SQL Server"

    # Start building the remediation script
    local sql=""

    sql+="-------------------------------------------------------------------------------
-- CDC Remediation Script for SQL Server
-- Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
-- Target: ${SQLSERVER_HOST} / [${SQLSERVER_DATABASE}]
-- User: ${SQLSERVER_USER}
--
-- This script is idempotent — safe to re-run.
-- Review each section before executing.
--
-- Run with:
--   SQLCMDPASSWORD=\"\$SQLSERVER_PASSWORD\" sqlcmd -S ${SQLSERVER_HOST},${SQLSERVER_PORT} \\
--     -U ${SQLSERVER_USER} -d ${SQLSERVER_DATABASE} -C -i db-prep/remediation-sqlserver.sql
-------------------------------------------------------------------------------

"

    # --- Check 1: Database exists ---
    DB_EXISTS=$($SQLCMD_BASE -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '${SQLSERVER_DATABASE}'" 2>/dev/null | tr -d '[:space:]')
    if [[ "$DB_EXISTS" != "1" ]]; then
        err "Database [${SQLSERVER_DATABASE}] does not exist"
        sql+="-- *** MANUAL ACTION REQUIRED ***
-- Database [${SQLSERVER_DATABASE}] does not exist.
-- If this is a new deployment, uncomment the line below.
-- If the database has a different name, update SQLSERVER_DATABASE in .env.
--
-- CREATE DATABASE [${SQLSERVER_DATABASE}];
-- GO

"
        needs_remediation=true
        # Can't continue checks without the database
        if [[ "$needs_remediation" == "true" ]]; then
            echo "$sql" > "$out"
            echo ""
            action "Generated: $out"
            info "Database does not exist — remediation script has limited scope"
        fi
        unset SQLCMDPASSWORD
        return
    fi
    ok "Database [${SQLSERVER_DATABASE}] exists"

    sql+="USE [${SQLSERVER_DATABASE}];
GO

"

    # --- Check 2: db_owner role ---
    IS_DB_OWNER=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT IS_MEMBER('db_owner')" 2>/dev/null | tr -d '[:space:]')
    if [[ "$IS_DB_OWNER" != "1" ]]; then
        action "Will grant db_owner to ${SQLSERVER_USER}"
        sql+="-------------------------------------------------------------------------------
-- Grant db_owner (required for Debezium CDC metadata access on RDS)
-------------------------------------------------------------------------------
IF IS_MEMBER('db_owner') = 0
BEGIN
    EXEC sp_addrolemember 'db_owner', '${SQLSERVER_USER}';
    PRINT 'Granted db_owner to ${SQLSERVER_USER}';
END
GO

"
        needs_remediation=true
    else
        ok "${SQLSERVER_USER} has db_owner"
    fi

    # --- Check 3: CDC enabled at database level ---
    CDC_ENABLED=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()" 2>/dev/null | tr -d '[:space:]')
    if [[ "$CDC_ENABLED" != "1" ]]; then
        action "Will enable CDC on database"
        sql+="-------------------------------------------------------------------------------
-- Enable CDC at database level
-- Uses RDS-specific procedure (works on both RDS and self-hosted)
-------------------------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.databases WHERE name = DB_NAME() AND is_cdc_enabled = 1)
BEGIN
    EXEC msdb.dbo.rds_cdc_enable_db '${SQLSERVER_DATABASE}';
    PRINT 'CDC enabled on [${SQLSERVER_DATABASE}]';
END
GO

"
        needs_remediation=true
    else
        ok "CDC enabled on [${SQLSERVER_DATABASE}]"
    fi

    # --- Check 4: CDC-enabled tables ---
    CDC_TABLE_COUNT=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM cdc.change_tables" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$CDC_TABLE_COUNT" || "$CDC_TABLE_COUNT" -eq 0 ]] 2>/dev/null; then
        action "No tables have CDC enabled — will generate enable commands for user tables"

        # Query all user tables
        USER_TABLES=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "
            SET NOCOUNT ON;
            SELECT SCHEMA_NAME(schema_id)+'.'+name
            FROM sys.tables
            WHERE type = 'U'
              AND name NOT LIKE 'sys%'
              AND name NOT LIKE 'cdc%'
              AND schema_id = SCHEMA_ID('dbo')
            ORDER BY name" 2>/dev/null | tr -d '\r' | sed '/^$/d')

        if [[ -n "$USER_TABLES" ]]; then
            sql+="-------------------------------------------------------------------------------
-- Enable CDC on tables
-- REVIEW: Uncomment the tables you want to replicate via CDC.
-- Tables without CDC enabled will NOT be captured by Debezium.
--
-- Tables with a primary key: use @supports_net_changes = 1
-- Tables without a primary key: use @supports_net_changes = 0
--   and set SQLSERVER_MESSAGE_KEY_COLUMNS in .env
-------------------------------------------------------------------------------
"
            while IFS= read -r tbl; do
                [[ -z "$tbl" ]] && continue
                tbl_schema="${tbl%%.*}"
                tbl_name="${tbl##*.}"

                # Check if table has a PK
                HAS_PK=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.indexes WHERE object_id = OBJECT_ID('${tbl}') AND is_primary_key = 1" 2>/dev/null | tr -d '[:space:]')
                if [[ "$HAS_PK" == "1" ]]; then
                    NET_CHANGES=1
                    PK_NOTE="-- Has PRIMARY KEY"
                else
                    NET_CHANGES=0
                    PK_NOTE="-- NO primary key — set SQLSERVER_MESSAGE_KEY_COLUMNS in .env for this table"
                fi

                sql+="
${PK_NOTE}
IF NOT EXISTS (SELECT 1 FROM cdc.change_tables WHERE source_object_id = OBJECT_ID('${tbl}'))
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema  = N'${tbl_schema}',
        @source_name    = N'${tbl_name}',
        @role_name      = N'cdc_reader',
        @supports_net_changes = ${NET_CHANGES};
    PRINT 'CDC enabled on ${tbl}';
END
GO
"
            done <<< "$USER_TABLES"
            sql+="
"
        else
            sql+="-- No user tables found in dbo schema. Create your tables first, then re-run.

"
        fi
        needs_remediation=true
    else
        ok "$CDC_TABLE_COUNT table(s) have CDC enabled"
        # List them and check for tables WITHOUT CDC
        CDC_TABLES=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT SCHEMA_NAME(t.schema_id)+'.'+t.name FROM cdc.change_tables ct JOIN sys.tables t ON ct.source_object_id=t.object_id ORDER BY t.name" 2>/dev/null | tr -d '\r' | sed '/^$/d')
        while IFS= read -r tbl; do
            [[ -n "$tbl" ]] && ok "  CDC: $tbl"
        done <<< "$CDC_TABLES"

        # Find user tables NOT in CDC (might be intentional — selective replication)
        NON_CDC_TABLES=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "
            SET NOCOUNT ON;
            SELECT SCHEMA_NAME(t.schema_id)+'.'+t.name
            FROM sys.tables t
            WHERE t.type = 'U'
              AND t.name NOT LIKE 'sys%'
              AND t.schema_id = SCHEMA_ID('dbo')
              AND t.object_id NOT IN (SELECT source_object_id FROM cdc.change_tables)
            ORDER BY t.name" 2>/dev/null | tr -d '\r' | sed '/^$/d')

        if [[ -n "$NON_CDC_TABLES" ]]; then
            sql+="-------------------------------------------------------------------------------
-- Tables WITHOUT CDC enabled (not replicated — may be intentional)
-- Uncomment any you want to add to CDC replication.
-------------------------------------------------------------------------------
"
            while IFS= read -r tbl; do
                [[ -z "$tbl" ]] && continue
                tbl_schema="${tbl%%.*}"
                tbl_name="${tbl##*.}"
                info "  No CDC: $tbl (not replicated)"

                HAS_PK=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.indexes WHERE object_id = OBJECT_ID('${tbl}') AND is_primary_key = 1" 2>/dev/null | tr -d '[:space:]')
                NET_CHANGES=1
                PK_NOTE=""
                if [[ "$HAS_PK" != "1" ]]; then
                    NET_CHANGES=0
                    PK_NOTE="  -- NO primary key"
                fi

                sql+="/*
IF NOT EXISTS (SELECT 1 FROM cdc.change_tables WHERE source_object_id = OBJECT_ID('${tbl}'))
BEGIN
    EXEC sys.sp_cdc_enable_table
        @source_schema  = N'${tbl_schema}',
        @source_name    = N'${tbl_name}',
        @role_name      = N'cdc_reader',
        @supports_net_changes = ${NET_CHANGES};${PK_NOTE}
    PRINT 'CDC enabled on ${tbl}';
END
GO
*/
"
            done <<< "$NON_CDC_TABLES"
            sql+="
"
            needs_remediation=true
        fi
    fi

    # --- Check 5: CDC capture job ---
    CAPTURE_JOB=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM msdb.dbo.cdc_jobs WHERE job_type = 'capture' AND database_id = DB_ID()" 2>/dev/null | tr -d '[:space:]')
    if [[ "$CAPTURE_JOB" != "1" ]]; then
        action "Will configure CDC capture job"
        sql+="-------------------------------------------------------------------------------
-- Configure CDC capture job (polling interval, throughput)
-- Values from .env tuning profile
-------------------------------------------------------------------------------
EXEC sys.sp_cdc_change_job
    @job_type = 'capture',
    @pollinginterval = ${CDC_CAPTURE_POLLING:-0},
    @maxtrans        = ${CDC_CAPTURE_MAXTRANS:-10000},
    @maxscans        = ${CDC_CAPTURE_MAXSCANS:-100};
PRINT 'CDC capture job configured: polling=${CDC_CAPTURE_POLLING:-0}, maxtrans=${CDC_CAPTURE_MAXTRANS:-10000}, maxscans=${CDC_CAPTURE_MAXSCANS:-100}';
GO

"
        needs_remediation=true
    else
        ok "CDC capture job exists"
    fi

    # --- Check 6: cdc_reader user ---
    CDC_USER_EXISTS=$($SQLCMD_BASE -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.server_principals WHERE name = 'cdc_reader'" 2>/dev/null | tr -d '[:space:]')
    CDC_DB_USER_EXISTS=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.database_principals WHERE name = 'cdc_reader'" 2>/dev/null | tr -d '[:space:]')

    if [[ "$CDC_USER_EXISTS" != "1" || "$CDC_DB_USER_EXISTS" != "1" ]]; then
        action "Will create cdc_reader login/user"
        sql+="-------------------------------------------------------------------------------
-- Create CDC reader user (for JDBC Sink connector write access)
-- *** IMPORTANT: Replace <YOUR_CDC_READER_PASSWORD> with a strong password ***
-------------------------------------------------------------------------------
"
        if [[ "$CDC_USER_EXISTS" != "1" ]]; then
            sql+="IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = 'cdc_reader')
BEGIN
    CREATE LOGIN [cdc_reader] WITH PASSWORD = '<YOUR_CDC_READER_PASSWORD>';
    PRINT 'Created login cdc_reader';
END
GO

"
        fi
        if [[ "$CDC_DB_USER_EXISTS" != "1" ]]; then
            sql+="IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = 'cdc_reader')
BEGIN
    CREATE USER [cdc_reader] FOR LOGIN [cdc_reader];
    PRINT 'Created user cdc_reader in [${SQLSERVER_DATABASE}]';
END
GO

"
        fi
        sql+="EXEC sp_addrolemember 'db_datareader', 'cdc_reader';
EXEC sp_addrolemember 'db_owner', 'cdc_reader';
PRINT 'Granted CDC permissions to cdc_reader';
GO

"
        needs_remediation=true
    else
        ok "cdc_reader login and database user exist"
    fi

    # --- Add verification queries ---
    sql+="-------------------------------------------------------------------------------
-- Verification — run after applying remediation
-------------------------------------------------------------------------------
PRINT '';
PRINT '=== Verification ===';

PRINT 'Database CDC status:';
SELECT name, is_cdc_enabled FROM sys.databases WHERE name = DB_NAME();

PRINT 'CDC-enabled tables:';
SELECT
    SCHEMA_NAME(t.schema_id) AS [schema],
    t.name AS [table],
    ct.capture_instance,
    ct.supports_net_changes
FROM cdc.change_tables ct
JOIN sys.tables t ON ct.source_object_id = t.object_id
ORDER BY t.name;

PRINT 'CDC capture job:';
SELECT job_type, maxtrans, maxscans, pollinginterval
FROM msdb.dbo.cdc_jobs
WHERE database_id = DB_ID();

PRINT 'cdc_reader permissions:';
SELECT dp.name, dp.type_desc,
       (SELECT STRING_AGG(r.name, ', ') FROM sys.database_role_members drm
        JOIN sys.database_principals r ON drm.role_principal_id = r.principal_id
        WHERE drm.member_principal_id = dp.principal_id) AS roles
FROM sys.database_principals dp
WHERE dp.name = 'cdc_reader';
GO
"

    unset SQLCMDPASSWORD

    if [[ "$needs_remediation" == "true" ]]; then
        echo "$sql" > "$out"
        echo ""
        action "Generated: $out"
    else
        echo ""
        ok "SQL Server: no remediation needed"
        # Clean up stale file
        rm -f "$out"
    fi
}

# ============================================================
# Aurora PostgreSQL Remediation
# ============================================================

generate_aurora() {
    local out="$OUTPUT_DIR/remediation-aurora.sql"
    local needs_remediation=false

    echo ""
    info "Connecting to Aurora PostgreSQL (${AURORA_HOST})..."

    if ! command -v psql &>/dev/null; then
        err "psql not installed — skipping Aurora"
        return
    fi

    export PGPASSWORD="${AURORA_PASSWORD}"
    export PGCONNECT_TIMEOUT=10
    PSQL_BASE="psql -h ${AURORA_HOST} -p ${AURORA_PORT} -U ${AURORA_USER} -d ${AURORA_DATABASE} -tAX -v ON_ERROR_STOP=1"

    if ! $PSQL_BASE -c "SELECT 1" &>/dev/null; then
        err "Cannot connect to Aurora — check AURORA_HOST/USER/PASSWORD/DATABASE in .env"
        unset PGPASSWORD PGCONNECT_TIMEOUT
        return
    fi
    ok "Connected to Aurora (${AURORA_USER}@${AURORA_DATABASE})"

    local sql=""

    sql+="-------------------------------------------------------------------------------
-- CDC Remediation Script for Aurora PostgreSQL
-- Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')
-- Target: ${AURORA_HOST} / ${AURORA_DATABASE}
-- User: ${AURORA_USER}
--
-- This script is idempotent — safe to re-run.
-- Review each section before executing.
--
-- Run with:
--   PGPASSWORD=\"\$AURORA_PASSWORD\" psql -h ${AURORA_HOST} -p ${AURORA_PORT} \\
--     -U ${AURORA_USER} -d ${AURORA_DATABASE} -f db-prep/remediation-aurora.sql
-------------------------------------------------------------------------------

"

    # --- Check 1: rds.logical_replication ---
    LOGICAL_REP=$($PSQL_BASE -c "SHOW rds.logical_replication" 2>/dev/null | tr -d '[:space:]')
    if [[ "$LOGICAL_REP" != "on" ]]; then
        action "rds.logical_replication is OFF — requires AWS Console/CLI change"
        sql+="-------------------------------------------------------------------------------
-- *** MANUAL ACTION REQUIRED: rds.logical_replication ***
-- Current value: ${LOGICAL_REP:-off}
-- This CANNOT be changed via SQL. You must:
--   1. Go to AWS Console > RDS > Parameter Groups
--   2. Edit the cluster parameter group
--   3. Set rds.logical_replication = 1
--   4. Reboot the Aurora cluster (writer instance)
--   5. Re-run this script or ./scripts/1-validate-env.sh to verify
--
-- The check below will verify the setting after you apply it:
-------------------------------------------------------------------------------
DO \$\$
BEGIN
    IF current_setting('rds.logical_replication') != 'on' THEN
        RAISE EXCEPTION 'rds.logical_replication is still OFF — apply parameter group change and reboot first';
    END IF;
    IF current_setting('wal_level') != 'logical' THEN
        RAISE EXCEPTION 'wal_level is %, expected logical — reboot required after parameter change', current_setting('wal_level');
    END IF;
    RAISE NOTICE 'rds.logical_replication = on, wal_level = logical ✓';
END
\$\$;

"
        needs_remediation=true
    else
        ok "rds.logical_replication = on"

        WAL_LEVEL=$($PSQL_BASE -c "SHOW wal_level" 2>/dev/null | tr -d '[:space:]')
        if [[ "$WAL_LEVEL" == "logical" ]]; then
            ok "wal_level = logical"
        else
            action "wal_level = ${WAL_LEVEL} — needs reboot"
            sql+="-- wal_level is '${WAL_LEVEL}', expected 'logical'. Reboot Aurora writer instance.

"
            needs_remediation=true
        fi
    fi

    # --- Check 2: Admin replication privilege ---
    HAS_REPLICATION=$($PSQL_BASE -c "SELECT rolreplication FROM pg_roles WHERE rolname = current_user" 2>/dev/null | tr -d '[:space:]')
    HAS_RDS_SUPER=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_auth_members WHERE roleid = (SELECT oid FROM pg_roles WHERE rolname = 'rds_superuser') AND member = (SELECT oid FROM pg_roles WHERE rolname = current_user)" 2>/dev/null | tr -d '[:space:]')
    if [[ "$HAS_REPLICATION" != "t" && "$HAS_RDS_SUPER" != "1" ]]; then
        action "${AURORA_USER} lacks REPLICATION privilege"
        sql+="-------------------------------------------------------------------------------
-- *** MANUAL ACTION REQUIRED: REPLICATION privilege ***
-- ${AURORA_USER} needs REPLICATION for Debezium source connector.
-- On RDS Aurora, only rds_superuser members can have REPLICATION.
-- Ask your DBA to run (as the master/admin user):
--   GRANT rds_superuser TO ${AURORA_USER};
-- Or use a user that already has rds_superuser membership.
-------------------------------------------------------------------------------

"
        needs_remediation=true
    else
        ok "${AURORA_USER} has replication capability"
    fi

    # --- Check 3: cdc_reader role ---
    PG_PUB="${PG_PUBLICATION_NAME:-cdc_publication}"
    CDC_USER="cdc_reader"
    CDC_ROLE_EXISTS=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_roles WHERE rolname = '${CDC_USER}'" 2>/dev/null | tr -d '[:space:]')

    if [[ "$CDC_ROLE_EXISTS" != "1" ]]; then
        action "Will create ${CDC_USER} role"
        sql+="-------------------------------------------------------------------------------
-- Create CDC reader role (for JDBC Sink connector write access)
-- *** IMPORTANT: Replace <YOUR_CDC_READER_PASSWORD> with a strong password ***
-------------------------------------------------------------------------------
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${CDC_USER}') THEN
        CREATE ROLE ${CDC_USER} WITH LOGIN PASSWORD '<YOUR_CDC_READER_PASSWORD>' REPLICATION;
        RAISE NOTICE 'Created role ${CDC_USER}';
    END IF;
END
\$\$;

"
        needs_remediation=true
    else
        ok "Role ${CDC_USER} exists"
    fi

    # Always ensure schema permissions (idempotent)
    sql+="-------------------------------------------------------------------------------
-- Grant schema permissions to ${CDC_USER}
-- Idempotent — safe to re-run even if already granted
-------------------------------------------------------------------------------
GRANT USAGE ON SCHEMA public TO ${CDC_USER};
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${CDC_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${CDC_USER};

-- Write access for JDBC Sink (INSERT/UPDATE/DELETE + CREATE for auto.create)
GRANT INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${CDC_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT INSERT, UPDATE, DELETE ON TABLES TO ${CDC_USER};
GRANT CREATE ON SCHEMA public TO ${CDC_USER};

-- Sequence permissions (for SERIAL/IDENTITY columns)
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${CDC_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${CDC_USER};

"
    # This section is always emitted since it's idempotent and catches permission drift
    needs_remediation=true

    # --- Check 4: Replication slot ---
    PG_SLOT="${PG_SLOT_NAME:-debezium_cdc}"
    SLOT_EXISTS=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '${PG_SLOT}'" 2>/dev/null | tr -d '[:space:]')
    if [[ "$SLOT_EXISTS" != "1" ]]; then
        action "Will create replication slot '${PG_SLOT}'"
        sql+="-------------------------------------------------------------------------------
-- Create replication slot for Debezium
-------------------------------------------------------------------------------
SELECT pg_create_logical_replication_slot('${PG_SLOT}', 'pgoutput')
WHERE NOT EXISTS (
    SELECT 1 FROM pg_replication_slots WHERE slot_name = '${PG_SLOT}'
);

"
        needs_remediation=true
    else
        ok "Replication slot '${PG_SLOT}' exists"
    fi

    # --- Check 5: Publication ---
    PUB_EXISTS=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_publication WHERE pubname = '${PG_PUB}'" 2>/dev/null | tr -d '[:space:]')
    if [[ "$PUB_EXISTS" != "1" ]]; then
        action "Will create publication '${PG_PUB}'"

        # Find all user tables to suggest
        USER_TABLES=$($PSQL_BASE -c "
            SELECT schemaname||'.'||tablename
            FROM pg_tables
            WHERE schemaname = 'public'
              AND tablename NOT LIKE 'pg_%'
              AND tablename NOT LIKE 'sql_%'
            ORDER BY tablename" 2>/dev/null | sed '/^$/d')

        if [[ -n "$USER_TABLES" ]]; then
            sql+="-------------------------------------------------------------------------------
-- Create publication for CDC
-- REVIEW: Uncomment/edit the table list to match your replication needs.
-- Only tables in the publication are captured by Debezium.
-------------------------------------------------------------------------------
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_publication WHERE pubname = '${PG_PUB}') THEN
        CREATE PUBLICATION ${PG_PUB} FOR TABLE
"
            FIRST=true
            while IFS= read -r tbl; do
                [[ -z "$tbl" ]] && continue
                if [[ "$FIRST" == "true" ]]; then
                    sql+="            ${tbl}"
                    FIRST=false
                else
                    sql+=",
            ${tbl}"
                fi
            done <<< "$USER_TABLES"
            sql+=";
        RAISE NOTICE 'Created publication ${PG_PUB}';
    END IF;
END
\$\$;

-- Grant DML on published tables to ${CDC_USER}
"
            while IFS= read -r tbl; do
                [[ -z "$tbl" ]] && continue
                sql+="GRANT SELECT, INSERT, UPDATE, DELETE ON ${tbl} TO ${CDC_USER};
"
            done <<< "$USER_TABLES"
            sql+="
"
        else
            sql+="-- No user tables found in public schema. Create your tables first, then re-run.
-- CREATE PUBLICATION ${PG_PUB} FOR TABLE <schema>.<table1>, <schema>.<table2>;

"
        fi
        needs_remediation=true
    else
        ok "Publication '${PG_PUB}' exists"

        # Check for tables NOT in publication
        PUB_ALL=$($PSQL_BASE -c "SELECT puballtables FROM pg_publication WHERE pubname = '${PG_PUB}'" 2>/dev/null | tr -d '[:space:]')
        if [[ "$PUB_ALL" != "t" ]]; then
            # List published tables
            PUB_TABLES=$($PSQL_BASE -c "SELECT schemaname||'.'||tablename FROM pg_publication_tables WHERE pubname = '${PG_PUB}' ORDER BY tablename" 2>/dev/null | sed '/^$/d')
            while IFS= read -r tbl; do
                [[ -n "$tbl" ]] && ok "  Published: $tbl"
            done <<< "$PUB_TABLES"

            # Tables not in publication
            NON_PUB_TABLES=$($PSQL_BASE -c "
                SELECT schemaname||'.'||tablename
                FROM pg_tables
                WHERE schemaname = 'public'
                  AND tablename NOT LIKE 'pg_%'
                  AND tablename NOT LIKE 'sql_%'
                  AND tablename NOT IN (
                      SELECT tablename FROM pg_publication_tables WHERE pubname = '${PG_PUB}'
                  )
                ORDER BY tablename" 2>/dev/null | sed '/^$/d')

            if [[ -n "$NON_PUB_TABLES" ]]; then
                sql+="-------------------------------------------------------------------------------
-- Tables NOT in publication '${PG_PUB}' (not replicated — may be intentional)
-- Uncomment any you want to add to CDC replication.
-------------------------------------------------------------------------------
"
                while IFS= read -r tbl; do
                    [[ -z "$tbl" ]] && continue
                    info "  Not published: $tbl (not replicated)"
                    sql+="-- ALTER PUBLICATION ${PG_PUB} ADD TABLE ${tbl};
-- GRANT SELECT, INSERT, UPDATE, DELETE ON ${tbl} TO ${CDC_USER};
"
                done <<< "$NON_PUB_TABLES"
                sql+="
"
                needs_remediation=true
            fi

            # Check published tables have no-PK issues
            PUB_TABLES_LIST=$($PSQL_BASE -c "SELECT schemaname||'.'||tablename FROM pg_publication_tables WHERE pubname = '${PG_PUB}' ORDER BY tablename" 2>/dev/null | sed '/^$/d')
            NO_PK_TABLES=""
            while IFS= read -r tbl; do
                [[ -z "$tbl" ]] && continue
                tbl_name="${tbl##*.}"
                HAS_PK=$($PSQL_BASE -c "
                    SELECT COUNT(*) FROM pg_constraint c
                    JOIN pg_class r ON c.conrelid = r.oid
                    JOIN pg_namespace n ON r.relnamespace = n.oid
                    WHERE c.contype = 'p'
                      AND n.nspname||'.'||r.relname = '${tbl}'" 2>/dev/null | tr -d '[:space:]')
                if [[ "$HAS_PK" == "0" ]]; then
                    NO_PK_TABLES+="$tbl "
                fi
            done <<< "$PUB_TABLES_LIST"

            if [[ -n "$NO_PK_TABLES" ]]; then
                sql+="-------------------------------------------------------------------------------
-- WARNING: These published tables have NO primary key:
--   ${NO_PK_TABLES}
--
-- Set AURORA_MESSAGE_KEY_COLUMNS in .env for these tables.
-- Format: <schema>.<table>:<col1>,<col2>
-- Example: public.audit_log:event_timestamp,source_type,source_id
-------------------------------------------------------------------------------

"
                needs_remediation=true
            fi
        fi
    fi

    # --- Verification ---
    sql+="-------------------------------------------------------------------------------
-- Verification — run after applying remediation
-------------------------------------------------------------------------------
\\echo ''
\\echo '=== Verification ==='

\\echo 'Replication settings:'
SHOW rds.logical_replication;
SHOW wal_level;

\\echo 'Replication slots:'
SELECT slot_name, plugin, slot_type, active FROM pg_replication_slots;

\\echo 'Publications:'
SELECT pubname, puballtables FROM pg_publication;

\\echo 'Published tables:'
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = '${PG_PUB}' ORDER BY tablename;

\\echo 'CDC reader role:'
SELECT rolname, rolcanlogin, rolreplication FROM pg_roles WHERE rolname = '${CDC_USER}';

\\echo 'Schema privileges for ${CDC_USER}:'
SELECT table_schema, table_name, privilege_type
FROM information_schema.table_privileges
WHERE grantee = '${CDC_USER}' AND table_schema = 'public'
ORDER BY table_name, privilege_type;
"

    unset PGPASSWORD PGCONNECT_TIMEOUT

    if [[ "$needs_remediation" == "true" ]]; then
        echo "$sql" > "$out"
        echo ""
        action "Generated: $out"
    else
        echo ""
        ok "Aurora: no remediation needed"
        rm -f "$out"
    fi
}

# ============================================================
# Run both generators
# ============================================================

generate_sqlserver
generate_aurora

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

SS_FILE="$OUTPUT_DIR/remediation-sqlserver.sql"
AU_FILE="$OUTPUT_DIR/remediation-aurora.sql"

if [[ -f "$SS_FILE" || -f "$AU_FILE" ]]; then
    echo -e "${YELLOW}${BOLD}  Remediation scripts generated. Next steps:${RESET}"
    echo ""
    if [[ -f "$SS_FILE" ]]; then
        echo -e "  ${BOLD}SQL Server:${RESET}"
        echo -e "    1. Review: ${CYAN}$SS_FILE${RESET}"
        echo -e "    2. Run:    SQLCMDPASSWORD=\"\$SQLSERVER_PASSWORD\" sqlcmd -S \$SQLSERVER_HOST,\$SQLSERVER_PORT \\"
        echo -e "                 -U \$SQLSERVER_USER -d \$SQLSERVER_DATABASE -C -i $SS_FILE"
        echo ""
    fi
    if [[ -f "$AU_FILE" ]]; then
        echo -e "  ${BOLD}Aurora PostgreSQL:${RESET}"
        echo -e "    1. Review: ${CYAN}$AU_FILE${RESET}"
        echo -e "    2. Run:    PGPASSWORD=\"\$AURORA_PASSWORD\" psql -h \$AURORA_HOST -p \$AURORA_PORT \\"
        echo -e "                 -U \$AURORA_USER -d \$AURORA_DATABASE -f $AU_FILE"
        echo ""
    fi
    echo -e "  ${BOLD}After applying:${RESET}"
    echo -e "    ./scripts/1-validate-env.sh    # Verify all checks pass"
else
    echo -e "  ${GREEN}${BOLD}Both databases are CDC-ready. No remediation needed.${RESET}"
fi
echo ""
