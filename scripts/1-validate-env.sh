#!/bin/bash
# ============================================================
# Phase 1: Full .env Audit + Database CDC Readiness
# ============================================================
# Compares .env against .env.template to find:
#   - Variables in template but missing from .env
#   - Variables in .env but not in template (stale/custom)
#   - Required variables that are blank
#   - Convention violations (unquoted special chars, bad escaping)
#   - Network connectivity to databases and brokers
#   - Database CDC readiness (SQL Server CDC + Aurora logical replication)
#
# Requires: sqlcmd (SQL Server checks), psql (Aurora checks)
#
# Usage: ./scripts/1-validate-env.sh
# ============================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

TEMPLATE_FILE="$REPO_DIR/.env.template"
ENV_FILE="$REPO_DIR/.env"

# --- Color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass()    { echo -e "  ${GREEN}✓${RESET} $1"; }
fail()    { echo -e "  ${RED}✗${RESET} $1"; }
warn()    { echo -e "  ${YELLOW}⚠${RESET} $1"; }
info()    { echo -e "${CYAN}[INFO]${RESET} $1"; }
section() { echo -e "\n${BOLD}$1${RESET}\n"; }

ERRORS=0
WARNINGS=0

# --- Pre-flight ---
if [[ ! -f "$TEMPLATE_FILE" ]]; then
    echo -e "${RED}ERROR: .env.template not found at $TEMPLATE_FILE${RESET}"
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo -e "${RED}ERROR: .env not found${RESET}"
    echo ""
    echo "Create one from template:"
    echo "   cp .env.template .env"
    echo "   # Edit .env with your values"
    echo "   ./scripts/1-validate-env.sh"
    exit 1
fi

# --- Extract variable names from a file (ignoring comments) ---
extract_vars() {
    grep -E '^\s*[A-Z_][A-Z_0-9]*=' "$1" | sed 's/[[:space:]]*#.*$//' | cut -d= -f1 | sort | uniq
}

# --- Get raw value (everything after first =) ---
get_raw_value() {
    local file="$1" var="$2"
    grep -E "^${var}=" "$file" | head -1 | cut -d= -f2-
}

TEMPLATE_VARS=$(extract_vars "$TEMPLATE_FILE")
ENV_VARS=$(extract_vars "$ENV_FILE")

echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  .env Full Audit — Phase 1${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"

# ============================================================
# Section 1: Missing from .env (in template but not in .env)
# ============================================================
section "1. Variables in .env.template but MISSING from .env"

MISSING_FROM_ENV=()
while IFS= read -r var; do
    if ! echo "$ENV_VARS" | grep -qx "$var"; then
        MISSING_FROM_ENV+=("$var")
    fi
done <<< "$TEMPLATE_VARS"

if [[ ${#MISSING_FROM_ENV[@]} -eq 0 ]]; then
    pass "All template variables present in .env"
else
    for var in "${MISSING_FROM_ENV[@]}"; do
        fail "MISSING: $var"
        ERRORS=$((ERRORS + 1))
    done
fi

# ============================================================
# Section 2: Extra in .env (not in template — stale or custom)
# ============================================================
section "2. Variables in .env but NOT in .env.template (stale/custom)"

EXTRA_IN_ENV=()
while IFS= read -r var; do
    if ! echo "$TEMPLATE_VARS" | grep -qx "$var"; then
        EXTRA_IN_ENV+=("$var")
    fi
done <<< "$ENV_VARS"

if [[ ${#EXTRA_IN_ENV[@]} -eq 0 ]]; then
    pass "No extra variables — .env matches template exactly"
else
    for var in "${EXTRA_IN_ENV[@]}"; do
        warn "EXTRA: $var (not in template — stale or custom addition)"
        WARNINGS=$((WARNINGS + 1))
    done
fi

# ============================================================
# Section 3: Required variables that are blank
# ============================================================
section "3. Required variables — blank value check"

# Variables that are allowed to be blank (optional by design)
OPTIONAL_VARS=(
    "HTTP_PROXY" "HTTPS_PROXY" "NO_PROXY" "PROXY_HOST" "PROXY_PORT"
    "SQLSERVER_MESSAGE_KEY_COLUMNS" "AURORA_MESSAGE_KEY_COLUMNS"
    "SSH_KEY_PATH"
    "BROKER_1_INSTANCE_ID" "BROKER_2_INSTANCE_ID" "BROKER_3_INSTANCE_ID"
    "CONNECT_1_INSTANCE_ID" "MONITOR_1_INSTANCE_ID"
)

is_optional() {
    local var="$1"
    for opt in "${OPTIONAL_VARS[@]}"; do
        [[ "$var" == "$opt" ]] && return 0
    done
    return 1
}

# Source .env to check values (with set -a for export)
set -a
source "$ENV_FILE"
set +a

BLANK_REQUIRED=()
BLANK_OPTIONAL=()
POPULATED=0

while IFS= read -r var; do
    # Get value from sourced env
    value="${!var:-}"
    # Strip surrounding single quotes if present (source .env keeps them for some values)
    value_clean=$(echo "$value" | sed "s/^'//;s/'$//")

    if [[ -z "$value_clean" ]]; then
        if is_optional "$var"; then
            BLANK_OPTIONAL+=("$var")
        else
            BLANK_REQUIRED+=("$var")
        fi
    else
        POPULATED=$((POPULATED + 1))
    fi
done <<< "$ENV_VARS"

if [[ ${#BLANK_REQUIRED[@]} -eq 0 ]]; then
    pass "All required variables have values ($POPULATED populated)"
else
    for var in "${BLANK_REQUIRED[@]}"; do
        fail "BLANK: $var (required — must be set before deployment)"
        ERRORS=$((ERRORS + 1))
    done
fi

if [[ ${#BLANK_OPTIONAL[@]} -gt 0 ]]; then
    for var in "${BLANK_OPTIONAL[@]}"; do
        pass "$var = (blank — optional, OK)"
    done
fi

# ============================================================
# Section 4: Dispatch mode validation
# ============================================================
section "4. Dispatch mode checks"

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
info "DISPATCH_MODE=$DISPATCH_MODE"

if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    if [[ -z "${SSH_KEY_PATH:-}" ]]; then
        fail "SSH_KEY_PATH is required when DISPATCH_MODE=ssh"
        ERRORS=$((ERRORS + 1))
    else
        # Expand ~ for existence check
        EXPANDED_KEY="${SSH_KEY_PATH/#\~/$HOME}"
        if [[ -f "$EXPANDED_KEY" ]]; then
            pass "SSH_KEY_PATH=$SSH_KEY_PATH (file exists)"
        else
            fail "SSH_KEY_PATH=$SSH_KEY_PATH (file NOT found: $EXPANDED_KEY)"
            ERRORS=$((ERRORS + 1))
        fi
    fi
    pass "Instance IDs not required in ssh mode"
elif [[ "$DISPATCH_MODE" == "ssm" ]]; then
    SSM_MISSING=0
    for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID; do
        if [[ -z "${!var:-}" ]]; then
            fail "$var is required when DISPATCH_MODE=ssm"
            SSM_MISSING=$((SSM_MISSING + 1))
            ERRORS=$((ERRORS + 1))
        fi
    done
    if [[ $SSM_MISSING -eq 0 ]]; then
        pass "All 5 instance IDs set for SSM mode"
    fi
else
    fail "DISPATCH_MODE='$DISPATCH_MODE' — must be 'ssh' or 'ssm'"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# Section 5: Convention & escaping checks
# ============================================================
section "5. Convention & escaping audit"

CONVENTION_ISSUES=0

# Check TOPIC_REGEX values have capture group (.+)
for var in JDBC_SINK_AURORA_TOPIC_REGEX JDBC_SINK_SQLSERVER_TOPIC_REGEX; do
    raw=$(get_raw_value "$ENV_FILE" "$var")
    if [[ -n "$raw" ]]; then
        if ! echo "$raw" | grep -q '(.*)' && ! echo "$raw" | grep -q '(.+)'; then
            fail "$var missing capture group (.+) — RegexRouter \$1 will produce empty string"
            ERRORS=$((ERRORS + 1))
            CONVENTION_ISSUES=$((CONVENTION_ISSUES + 1))
        else
            pass "$var has capture group"
        fi
        # Must be single-quoted
        if [[ "$raw" == \'* ]]; then
            pass "$var is single-quoted (protects parentheses from bash)"
        else
            fail "$var must be single-quoted (unquoted parentheses break 'source .env')"
            ERRORS=$((ERRORS + 1))
            CONVENTION_ISSUES=$((CONVENTION_ISSUES + 1))
        fi
    fi
done

# Check TOPICS_REGEX values have escaped dots
for var in JDBC_SINK_AURORA_TOPICS_REGEX JDBC_SINK_SQLSERVER_TOPICS_REGEX; do
    raw=$(get_raw_value "$ENV_FILE" "$var")
    if [[ -n "$raw" ]]; then
        if echo "$raw" | grep -q '\\\.'; then
            pass "$var has escaped dots (\\\\.) for Java regex literal dot matching"
        else
            warn "$var may not have escaped dots — unescaped dots match ANY character in Java regex"
            WARNINGS=$((WARNINGS + 1))
            CONVENTION_ISSUES=$((CONVENTION_ISSUES + 1))
        fi
        # Should NOT be quoted
        if [[ "$raw" == \'* ]] || [[ "$raw" == \"* ]]; then
            fail "$var should NOT be quoted (quotes become part of the regex value)"
            ERRORS=$((ERRORS + 1))
            CONVENTION_ISSUES=$((CONVENTION_ISSUES + 1))
        else
            pass "$var is unquoted (correct)"
        fi
    fi
done

# Check passwords with special chars are single-quoted
for var in AURORA_PASSWORD SQLSERVER_PASSWORD; do
    raw=$(get_raw_value "$ENV_FILE" "$var")
    if [[ -n "$raw" ]]; then
        # Check if value contains special chars that need quoting
        if echo "$raw" | grep -qE '[()$!{}|&<>]'; then
            if [[ "$raw" == \'* ]]; then
                pass "$var is single-quoted (has special characters)"
            else
                fail "$var has special characters but is NOT single-quoted — may break 'source .env'"
                ERRORS=$((ERRORS + 1))
                CONVENTION_ISSUES=$((CONVENTION_ISSUES + 1))
            fi
        else
            pass "$var = ***"
        fi
    fi
done

# Check CLUSTER_ID is 22 chars URL-safe base64
if [[ -n "${CLUSTER_ID:-}" ]]; then
    if [[ ${#CLUSTER_ID} -eq 22 ]] && echo "$CLUSTER_ID" | grep -qE '^[A-Za-z0-9_-]+$'; then
        pass "CLUSTER_ID is valid (22-char URL-safe Base64)"
    else
        warn "CLUSTER_ID='$CLUSTER_ID' — expected 22-char URL-safe Base64"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# Check IP addresses are valid format
for var in BROKER_1_IP BROKER_2_IP BROKER_3_IP CONNECT_1_IP MONITOR_1_IP; do
    value="${!var:-}"
    if [[ -n "$value" ]]; then
        if echo "$value" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            pass "$var=$value (valid IPv4)"
        else
            fail "$var='$value' — not a valid IPv4 address"
            ERRORS=$((ERRORS + 1))
            CONVENTION_ISSUES=$((CONVENTION_ISSUES + 1))
        fi
    fi
done

# Check ports are numeric
for var in AURORA_PORT SQLSERVER_PORT SCHEMA_REGISTRY_PORT GRAFANA_PORT PROMETHEUS_PORT JMX_EXPORTER_PORT KSQLDB_PORT FLINK_JOBMANAGER_PORT; do
    value="${!var:-}"
    if [[ -n "$value" ]]; then
        if echo "$value" | grep -qE '^[0-9]+$'; then
            pass "$var=$value"
        else
            fail "$var='$value' — must be numeric"
            ERRORS=$((ERRORS + 1))
            CONVENTION_ISSUES=$((CONVENTION_ISSUES + 1))
        fi
    fi
done

if [[ $CONVENTION_ISSUES -eq 0 ]]; then
    pass "All convention checks passed"
fi

# ============================================================
# Section 6: Connectivity pre-check
# ============================================================
section "6. Network connectivity"

AURORA_REACHABLE=false
SQLSERVER_REACHABLE=false

check_port() {
    local host="$1" port="$2" label="$3"
    if timeout 3 bash -c "echo >/dev/tcp/$host/$port" 2>/dev/null; then
        pass "$label ($host:$port) — reachable"
        return 0
    else
        fail "$label ($host:$port) — not reachable"
        ERRORS=$((ERRORS + 1))
        return 1
    fi
}

if [[ -n "${AURORA_HOST:-}" && -n "${AURORA_PORT:-}" ]]; then
    if check_port "$AURORA_HOST" "$AURORA_PORT" "Aurora PostgreSQL"; then
        AURORA_REACHABLE=true
    fi
else
    fail "AURORA_HOST or AURORA_PORT not set — cannot check Aurora connectivity"
    ERRORS=$((ERRORS + 1))
fi
if [[ -n "${SQLSERVER_HOST:-}" && -n "${SQLSERVER_PORT:-}" ]]; then
    if check_port "$SQLSERVER_HOST" "$SQLSERVER_PORT" "SQL Server"; then
        SQLSERVER_REACHABLE=true
    fi
else
    fail "SQLSERVER_HOST or SQLSERVER_PORT not set — cannot check SQL Server connectivity"
    ERRORS=$((ERRORS + 1))
fi
if [[ -n "${BROKER_1_IP:-}" ]]; then
    check_port "$BROKER_1_IP" 22 "Broker-1 SSH"
fi

# ============================================================
# Section 7: Database CDC readiness
# ============================================================
section "7. Database CDC readiness"

# --- SQL Server checks ---
if [[ "$SQLSERVER_REACHABLE" == "true" ]]; then
    info "Checking SQL Server CDC prerequisites..."

    if ! command -v sqlcmd &>/dev/null; then
        fail "sqlcmd not installed — cannot validate SQL Server CDC (install: https://learn.microsoft.com/sql/tools/sqlcmd)"
        ERRORS=$((ERRORS + 1))
    else
        SQLCMD_BASE="sqlcmd -S ${SQLSERVER_HOST},${SQLSERVER_PORT} -U ${SQLSERVER_USER} -C -l 10 -h -1 -W"
        export SQLCMDPASSWORD="${SQLSERVER_PASSWORD}"

        # 7a. Auth check — can we log in?
        if ! $SQLCMD_BASE -Q "SELECT 1" &>/dev/null; then
            fail "SQL Server auth failed for ${SQLSERVER_USER}@${SQLSERVER_HOST} — check SQLSERVER_USER/PASSWORD"
            ERRORS=$((ERRORS + 1))
        else
            pass "SQL Server auth OK (${SQLSERVER_USER})"

            # 7b. Database exists
            DB_EXISTS=$($SQLCMD_BASE -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.databases WHERE name = '${SQLSERVER_DATABASE}'" 2>/dev/null | tr -d '[:space:]')
            if [[ "$DB_EXISTS" == "1" ]]; then
                pass "Database [${SQLSERVER_DATABASE}] exists"

                # 7b2. User has db_owner on target database (required for CDC metadata access on RDS)
                IS_DB_OWNER=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT IS_MEMBER('db_owner')" 2>/dev/null | tr -d '[:space:]')
                if [[ "$IS_DB_OWNER" == "1" ]]; then
                    pass "${SQLSERVER_USER} has db_owner on [${SQLSERVER_DATABASE}]"
                else
                    fail "${SQLSERVER_USER} lacks db_owner on [${SQLSERVER_DATABASE}] — Debezium needs this on RDS for CDC access"
                    ERRORS=$((ERRORS + 1))
                fi

                # 7c. CDC enabled at database level
                CDC_ENABLED=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()" 2>/dev/null | tr -d '[:space:]')
                if [[ "$CDC_ENABLED" == "1" ]]; then
                    pass "CDC enabled on [${SQLSERVER_DATABASE}]"
                else
                    fail "CDC NOT enabled on [${SQLSERVER_DATABASE}] — run: EXEC msdb.dbo.rds_cdc_enable_db '${SQLSERVER_DATABASE}'"
                    ERRORS=$((ERRORS + 1))
                fi

                # 7d. At least one CDC-enabled table
                CDC_TABLE_COUNT=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM cdc.change_tables" 2>/dev/null | tr -d '[:space:]')
                if [[ -n "$CDC_TABLE_COUNT" && "$CDC_TABLE_COUNT" -gt 0 ]] 2>/dev/null; then
                    pass "$CDC_TABLE_COUNT table(s) with CDC enabled"
                    # List the tables for visibility
                    CDC_TABLES=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT SCHEMA_NAME(t.schema_id)+'.'+t.name FROM cdc.change_tables ct JOIN sys.tables t ON ct.source_object_id=t.object_id ORDER BY t.name" 2>/dev/null | tr -d '\r' | sed '/^$/d')
                    while IFS= read -r tbl; do
                        [[ -n "$tbl" ]] && info "  CDC table: $tbl"
                    done <<< "$CDC_TABLES"
                else
                    fail "No tables have CDC enabled — run sys.sp_cdc_enable_table on each table (see db-prep/prep-sqlserver.sql examples)"
                    ERRORS=$((ERRORS + 1))
                fi

                # 7e. CDC capture job running
                CAPTURE_JOB=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT COUNT(*) FROM msdb.dbo.cdc_jobs WHERE job_type = 'capture' AND database_id = DB_ID()" 2>/dev/null | tr -d '[:space:]')
                if [[ "$CAPTURE_JOB" == "1" ]]; then
                    pass "CDC capture job exists"
                else
                    warn "CDC capture job not found — CDC may not capture changes (auto-created when CDC is enabled)"
                    WARNINGS=$((WARNINGS + 1))
                fi

                # 7f. SQL Server Agent running (check for recent capture LSN activity)
                AGENT_CHECK=$($SQLCMD_BASE -d "${SQLSERVER_DATABASE}" -Q "SET NOCOUNT ON; SELECT CASE WHEN MAX(tran_end_time) > DATEADD(HOUR, -24, GETDATE()) THEN 1 WHEN (SELECT COUNT(*) FROM cdc.change_tables) > 0 THEN 0 ELSE -1 END FROM cdc.lsn_time_mapping" 2>/dev/null | tr -d '[:space:]')
                if [[ "$AGENT_CHECK" == "1" ]]; then
                    pass "SQL Server Agent CDC capture is active (recent LSN activity)"
                elif [[ "$AGENT_CHECK" == "0" ]]; then
                    warn "No recent CDC capture activity — SQL Server Agent may not be running"
                    WARNINGS=$((WARNINGS + 1))
                fi
            else
                fail "Database [${SQLSERVER_DATABASE}] does not exist — create it or update SQLSERVER_DATABASE in .env"
                ERRORS=$((ERRORS + 1))
            fi
        fi
        unset SQLCMDPASSWORD
    fi
else
    fail "SQL Server not reachable — skipping CDC readiness checks"
    ERRORS=$((ERRORS + 1))
fi

echo ""

# --- Aurora PostgreSQL checks ---
if [[ "$AURORA_REACHABLE" == "true" ]]; then
    info "Checking Aurora PostgreSQL CDC prerequisites..."

    if ! command -v psql &>/dev/null; then
        fail "psql not installed — cannot validate Aurora CDC (install: sudo dnf install postgresql15)"
        ERRORS=$((ERRORS + 1))
    else
        export PGPASSWORD="${AURORA_PASSWORD}"
        export PGCONNECT_TIMEOUT=10
        PSQL_BASE="psql -h ${AURORA_HOST} -p ${AURORA_PORT} -U ${AURORA_USER} -d ${AURORA_DATABASE} -tAX -v ON_ERROR_STOP=1"

        # 7g. Auth + database check
        if ! $PSQL_BASE -c "SELECT 1" &>/dev/null; then
            fail "Aurora auth failed for ${AURORA_USER}@${AURORA_HOST}/${AURORA_DATABASE} — check AURORA_USER/PASSWORD/DATABASE"
            ERRORS=$((ERRORS + 1))
        else
            pass "Aurora auth OK (${AURORA_USER}@${AURORA_DATABASE})"

            # 7g2. Admin user has replication privilege (Debezium source needs this)
            HAS_REPLICATION=$($PSQL_BASE -c "SELECT rolreplication FROM pg_roles WHERE rolname = current_user" 2>/dev/null | tr -d '[:space:]')
            if [[ "$HAS_REPLICATION" == "t" ]]; then
                pass "${AURORA_USER} has REPLICATION privilege"
            else
                # Check for rds_superuser membership (grants replication on RDS)
                HAS_RDS_SUPER=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_auth_members WHERE roleid = (SELECT oid FROM pg_roles WHERE rolname = 'rds_superuser') AND member = (SELECT oid FROM pg_roles WHERE rolname = current_user)" 2>/dev/null | tr -d '[:space:]')
                if [[ "$HAS_RDS_SUPER" == "1" ]]; then
                    pass "${AURORA_USER} is rds_superuser member (has replication)"
                else
                    fail "${AURORA_USER} lacks REPLICATION privilege — Debezium source connector requires this. On RDS, only rds_superuser members can replicate"
                    ERRORS=$((ERRORS + 1))
                fi
            fi

            # 7h. Logical replication enabled
            LOGICAL_REP=$($PSQL_BASE -c "SHOW rds.logical_replication" 2>/dev/null | tr -d '[:space:]')
            if [[ "$LOGICAL_REP" == "on" ]]; then
                pass "rds.logical_replication = on"
            else
                fail "rds.logical_replication = ${LOGICAL_REP:-off} — set to 1 in cluster parameter group and reboot"
                ERRORS=$((ERRORS + 1))
            fi

            # 7i. wal_level = logical
            WAL_LEVEL=$($PSQL_BASE -c "SHOW wal_level" 2>/dev/null | tr -d '[:space:]')
            if [[ "$WAL_LEVEL" == "logical" ]]; then
                pass "wal_level = logical"
            else
                fail "wal_level = ${WAL_LEVEL:-unknown} (expected: logical) — reboot Aurora after setting rds.logical_replication=1"
                ERRORS=$((ERRORS + 1))
            fi

            # 7j. Replication slot exists
            PG_SLOT="${PG_SLOT_NAME:-debezium_cdc}"
            SLOT_EXISTS=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = '${PG_SLOT}'" 2>/dev/null | tr -d '[:space:]')
            if [[ "$SLOT_EXISTS" == "1" ]]; then
                pass "Replication slot '${PG_SLOT}' exists"
                # Check if slot is active (held by another connection)
                SLOT_ACTIVE=$($PSQL_BASE -c "SELECT active FROM pg_replication_slots WHERE slot_name = '${PG_SLOT}'" 2>/dev/null | tr -d '[:space:]')
                if [[ "$SLOT_ACTIVE" == "t" ]]; then
                    warn "Replication slot '${PG_SLOT}' is currently active — another consumer is connected"
                    WARNINGS=$((WARNINGS + 1))
                fi
            else
                fail "Replication slot '${PG_SLOT}' not found — run: SELECT pg_create_logical_replication_slot('${PG_SLOT}', 'pgoutput')"
                ERRORS=$((ERRORS + 1))
            fi

            # 7k. Publication exists
            PG_PUB="${PG_PUBLICATION_NAME:-cdc_publication}"
            PUB_EXISTS=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_publication WHERE pubname = '${PG_PUB}'" 2>/dev/null | tr -d '[:space:]')
            if [[ "$PUB_EXISTS" == "1" ]]; then
                pass "Publication '${PG_PUB}' exists"

                # 7l. Publication has tables
                PUB_ALL=$($PSQL_BASE -c "SELECT puballtables FROM pg_publication WHERE pubname = '${PG_PUB}'" 2>/dev/null | tr -d '[:space:]')
                if [[ "$PUB_ALL" == "t" ]]; then
                    pass "Publication '${PG_PUB}' publishes ALL tables"
                else
                    PUB_TABLE_COUNT=$($PSQL_BASE -c "SELECT COUNT(*) FROM pg_publication_tables WHERE pubname = '${PG_PUB}'" 2>/dev/null | tr -d '[:space:]')
                    if [[ -n "$PUB_TABLE_COUNT" && "$PUB_TABLE_COUNT" -gt 0 ]] 2>/dev/null; then
                        pass "Publication '${PG_PUB}' has $PUB_TABLE_COUNT table(s)"
                        PUB_TABLES=$($PSQL_BASE -c "SELECT schemaname||'.'||tablename FROM pg_publication_tables WHERE pubname = '${PG_PUB}' ORDER BY tablename" 2>/dev/null)
                        while IFS= read -r tbl; do
                            [[ -n "$tbl" ]] && info "  Published table: $tbl"
                        done <<< "$PUB_TABLES"
                    else
                        fail "Publication '${PG_PUB}' has no tables — add tables: ALTER PUBLICATION ${PG_PUB} ADD TABLE <schema>.<table>"
                        ERRORS=$((ERRORS + 1))
                    fi
                fi
            else
                fail "Publication '${PG_PUB}' not found — run: CREATE PUBLICATION ${PG_PUB} FOR TABLE <your_tables>"
                ERRORS=$((ERRORS + 1))
            fi

        fi
        unset PGPASSWORD PGCONNECT_TIMEOUT
    fi
else
    fail "Aurora PostgreSQL not reachable — skipping CDC readiness checks"
    ERRORS=$((ERRORS + 1))
fi

# ============================================================
# Summary
# ============================================================
section "═══════════════════════════════════════════════════════════"

TOTAL_TEMPLATE=$(echo "$TEMPLATE_VARS" | wc -l)
TOTAL_ENV=$(echo "$ENV_VARS" | wc -l)

echo -e "  Template vars:     $TOTAL_TEMPLATE"
echo -e "  .env vars:         $TOTAL_ENV"
echo -e "  Populated:         $POPULATED"
echo -e "  Missing from .env: ${#MISSING_FROM_ENV[@]}"
echo -e "  Extra in .env:     ${#EXTRA_IN_ENV[@]}"
echo -e "  Blank (required):  ${#BLANK_REQUIRED[@]}"
echo -e "  Blank (optional):  ${#BLANK_OPTIONAL[@]}"
echo ""

if [[ $ERRORS -gt 0 ]]; then
    echo -e "  ${RED}${BOLD}RESULT: $ERRORS error(s), $WARNINGS warning(s) — FIX BEFORE DEPLOYMENT${RESET}"
    echo ""
    exit 1
elif [[ $WARNINGS -gt 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}RESULT: PASS with $WARNINGS warning(s)${RESET}"
    echo ""
    echo "  Warnings are advisory — deployment may still succeed."
    exit 0
else
    echo -e "  ${GREEN}${BOLD}RESULT: ALL CHECKS PASSED${RESET}"
    echo ""
    echo "  .env is fully aligned with .env.template. Ready for deployment."
    exit 0
fi
