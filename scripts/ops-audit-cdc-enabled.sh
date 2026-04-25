#!/bin/bash
###############################################################################
# CDC Table Audit — ops-audit-cdc-enabled.sh
#
# Audit which tables have Change Data Capture enabled on SQL Server or
# Aurora PostgreSQL. Scoped by database and schema so it never scans the
# entire server — safe to run against large production instances.
#
# Runs from the jumpbox (or any host with network access to the DB).
# Queries databases directly via sqlcmd / psql — no SSM dispatch needed.
#
# ─── What it reports ────────────────────────────────────────────────────
#
# SQL Server (--sqlserver):
#   • Database-level CDC status (is_cdc_enabled)
#   • CDC-enabled tables: schema, table, capture instance, net changes
#     support, and the date CDC was enabled
#   • Tables WITHOUT CDC in the same schema (with PK info)
#   • CDC capture/cleanup job configuration (polling interval, maxtrans,
#     maxscans, retention)
#
# Aurora PostgreSQL (--aurora):
#   • Logical replication prerequisites (wal_level, rds.logical_replication)
#   • Replication slots (name, plugin, type, active/inactive, restart LSN)
#   • Publications defined on the database
#   • Tables IN the publication for the target schema (with PK info)
#   • Tables NOT in the publication (candidates to add)
#
# ─── Prerequisites ──────────────────────────────────────────────────────
#
# SQL Server: sqlcmd (mssql-tools18) must be on PATH.
#   Install: sudo yum install -y mssql-tools18   (Amazon Linux)
#            brew install mssql-tools18           (macOS)
#
# Aurora PG:  psql (postgresql client) must be on PATH.
#   Install: sudo yum install -y postgresql15     (Amazon Linux)
#            brew install libpq                   (macOS)
#
# ─── Connection Defaults ────────────────────────────────────────────────
#
# All connection parameters default from .env (auto-loaded from ../. env
# relative to this script). Override any value with CLI flags:
#
#   .env variable            CLI flag          Default
#   ─────────────────────    ──────────────    ──────────────────────
#   SQLSERVER_HOST           --host            (required)
#   SQLSERVER_PORT           --port            1433
#   SQLSERVER_USER           --user            (required)
#   SQLSERVER_PASSWORD       --password        (required)
#   SQLSERVER_DATABASE       --database        (required)
#   (n/a)                    --schema          dbo
#
#   AURORA_HOST              --host            (required)
#   AURORA_PORT              --port            5432
#   AURORA_USER              --user            (required)
#   AURORA_PASSWORD          --password        (required)
#   AURORA_DATABASE          --database        (required)
#   (n/a)                    --schema          public
#   PG_PUBLICATION_NAME      --publication     cdc_publication
#
# ─── Usage ──────────────────────────────────────────────────────────────
#
#   bash scripts/ops-audit-cdc-enabled.sh --sqlserver [options]
#   bash scripts/ops-audit-cdc-enabled.sh --aurora [options]
#
# Options:
#   --sqlserver            Audit SQL Server CDC tables
#   --aurora               Audit Aurora PostgreSQL CDC tables
#   --both                 Audit both databases
#   (no flag)              Interactive menu — pick with a single keypress
#   --database <name>      Database name (overrides .env)
#   --schema <name>        Schema to audit (default: dbo / public)
#   --host <host>          Database host (overrides .env)
#   --port <port>          Database port (overrides .env)
#   --user <user>          Database user (overrides .env)
#   --password <pass>      Database password (overrides .env)
#   --publication <name>   Aurora publication name (overrides .env)
#   -h, --help             Show this help and exit
#
# ─── Examples ───────────────────────────────────────────────────────────
#
# Minimal (reads everything from .env):
#   bash scripts/ops-audit-cdc-enabled.sh --sqlserver
#   bash scripts/ops-audit-cdc-enabled.sh --aurora
#
# Specify database and schema:
#   bash scripts/ops-audit-cdc-enabled.sh --sqlserver --database pocdb --schema dbo
#   bash scripts/ops-audit-cdc-enabled.sh --aurora --database pocdb --schema public
#
# Override connection (e.g. different environment):
#   bash scripts/ops-audit-cdc-enabled.sh --sqlserver \
#     --host sqlserver-staging.example.com --database staging_db \
#     --user cdcadmin --password 'S3cur3!'
#
# Audit a non-default Aurora publication:
#   bash scripts/ops-audit-cdc-enabled.sh --aurora --publication my_pub
#
# Audit a non-public schema on Aurora:
#   bash scripts/ops-audit-cdc-enabled.sh --aurora --schema inventory
#
# ─── Output Legend ──────────────────────────────────────────────────────
#
#   ● (green)  = CDC enabled / in publication
#   ○ (grey)   = CDC not enabled / not in publication
#   ✓ (green)  = Check passed
#   ✗ (red)    = Check failed
#   ⚠ (yellow) = Warning or nothing found
#
###############################################################################

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# Load .env if it exists
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
  set +u
  source "$ENV_FILE"
  set -u
fi

TARGET=""
DB_HOST=""
DB_PORT=""
DB_USER=""
DB_PASS=""
DB_NAME=""
DB_SCHEMA=""
PUB_NAME=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --sqlserver)  TARGET="sqlserver"; shift ;;
    --aurora)     TARGET="aurora"; shift ;;
    --both)       TARGET="both"; shift ;;
    --database)   DB_NAME="$2"; shift 2 ;;
    --schema)     DB_SCHEMA="$2"; shift 2 ;;
    --host)       DB_HOST="$2"; shift 2 ;;
    --port)       DB_PORT="$2"; shift 2 ;;
    --user)       DB_USER="$2"; shift 2 ;;
    --password)   DB_PASS="$2"; shift 2 ;;
    --publication) PUB_NAME="$2"; shift 2 ;;
    -h|--help)
      cat <<'HELPEOF'
Usage: ops-audit-cdc-enabled.sh --sqlserver|--aurora [options]

Audit which tables have Change Data Capture enabled on a specific
database and schema. Safe to run against large instances — never
scans the entire server.

Target (interactive menu if omitted):
  --sqlserver            Audit SQL Server CDC tables
  --aurora               Audit Aurora PostgreSQL CDC tables
  --both                 Audit both databases

Connection (all default from .env):
  --host <host>          Database host
  --port <port>          Database port (default: 1433 / 5432)
  --user <user>          Database user
  --password <pass>      Database password
  --database <name>      Database name

Scope:
  --schema <name>        Schema to audit (default: dbo for SQL Server,
                         public for Aurora PostgreSQL)
  --publication <name>   Aurora publication name (default: PG_PUBLICATION_NAME
                         from .env, or cdc_publication)

General:
  -h, --help             Show this help and exit

SQL Server output:
  • Database-level CDC status
  • CDC-enabled tables (capture instance, net changes, enable date)
  • Tables without CDC in the same schema (with PK info)
  • CDC capture/cleanup job configuration

Aurora PostgreSQL output:
  • Logical replication status (wal_level, rds.logical_replication)
  • Replication slots (active/inactive)
  • Publications
  • Tables in the publication (with PK info)
  • Tables not in the publication

Prerequisites:
  SQL Server: sqlcmd (mssql-tools18) on PATH
  Aurora PG:  psql (postgresql client) on PATH

Examples:
  # Minimal — reads connection from .env:
  ops-audit-cdc-enabled.sh --sqlserver
  ops-audit-cdc-enabled.sh --aurora

  # Specify database and schema:
  ops-audit-cdc-enabled.sh --sqlserver --database pocdb --schema dbo
  ops-audit-cdc-enabled.sh --aurora --database pocdb --schema public

  # Override connection for a different environment:
  ops-audit-cdc-enabled.sh --sqlserver \
    --host sqlserver-staging.example.com --database staging_db \
    --user cdcadmin --password 'S3cur3!'

  # Audit a non-default publication:
  ops-audit-cdc-enabled.sh --aurora --publication my_pub

  # Audit a non-public schema:
  ops-audit-cdc-enabled.sh --aurora --schema inventory
HELPEOF
      exit 0
      ;;
    *)
      echo -e "${RED}Unknown option: $1${NC}"
      echo "Run with --help for usage."
      exit 1
      ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo ""
  echo -e "${BOLD}${BLUE}  Select database to audit:${NC}"
  echo ""
  echo -e "    ${BOLD}1${NC})  SQL Server"
  echo -e "    ${BOLD}2${NC})  Aurora PostgreSQL"
  echo -e "    ${BOLD}3${NC})  Both"
  echo ""
  printf "  Press ${BOLD}1${NC}, ${BOLD}2${NC}, or ${BOLD}3${NC}: "
  read -r -n 1 choice
  echo ""
  case "$choice" in
    1) TARGET="sqlserver" ;;
    2) TARGET="aurora" ;;
    3) TARGET="both" ;;
    *)
      echo -e "${RED}Invalid selection. Run with --help for usage.${NC}"
      exit 1
      ;;
  esac
fi

# ---------------------------------------------------------------------------
# SQL Server audit
# ---------------------------------------------------------------------------
audit_sqlserver() {
  local host="${DB_HOST:-${SQLSERVER_HOST:-}}"
  local port="${DB_PORT:-${SQLSERVER_PORT:-1433}}"
  local user="${DB_USER:-${SQLSERVER_USER:-}}"
  local pass="${DB_PASS:-${SQLSERVER_PASSWORD:-}}"
  local database="${DB_NAME:-${SQLSERVER_DATABASE:-}}"
  local schema="${DB_SCHEMA:-dbo}"

  if [[ -z "$host" || -z "$user" || -z "$pass" || -z "$database" ]]; then
    echo -e "${RED}Error: missing connection details. Set --host/--user/--password/--database or configure .env${NC}"
    exit 1
  fi

  if ! command -v sqlcmd &>/dev/null; then
    echo -e "${RED}Error: sqlcmd not found. Install with: sudo yum install -y mssql-tools18 || brew install mssql-tools18${NC}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║           SQL Server — CDC Table Audit                        ║${NC}"
  echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}${BLUE}─ Connection${NC}"
  echo -e "  Host:     ${host}:${port}"
  echo -e "  Database: ${database}"
  echo -e "  Schema:   ${schema}"
  echo -e "  User:     ${user}"
  echo ""

  # Check database-level CDC
  echo -e "${BOLD}${BLUE}─ Database CDC Status${NC}"
  local db_cdc
  db_cdc=$(SQLCMDPASSWORD="$pass" sqlcmd -S "${host},${port}" -U "$user" -d "$database" -C -h -1 -W -Q \
    "SET NOCOUNT ON; SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME();" 2>&1)

  if [[ $? -ne 0 ]]; then
    echo -e "  ${RED}✗ Connection failed${NC}"
    echo -e "  ${GREY}${db_cdc}${NC}"
    return 1
  fi

  db_cdc=$(echo "$db_cdc" | tr -d '[:space:]')
  if [[ "$db_cdc" == "1" ]]; then
    echo -e "  ${GREEN}✓${NC} CDC is ${GREEN}enabled${NC} on database [${database}]"
  else
    echo -e "  ${RED}✗${NC} CDC is ${RED}disabled${NC} on database [${database}]"
    echo ""
    echo -e "  ${GREY}Enable with: EXEC msdb.dbo.rds_cdc_enable_db '${database}';${NC}"
    return 0
  fi
  echo ""

  # List CDC-enabled tables
  echo -e "${BOLD}${BLUE}─ CDC-Enabled Tables (schema: ${schema})${NC}"

  local query
  query=$(cat <<'SQLEOF'
SET NOCOUNT ON;
SELECT
    s.name,
    t.name,
    ct.capture_instance,
    CASE ct.supports_net_changes WHEN 1 THEN 'Yes' ELSE 'No' END,
    CONVERT(VARCHAR(19), ct.create_date, 120),
    ISNULL((SELECT SUM(p.row_count) FROM sys.dm_db_partition_stats p WHERE p.object_id = t.object_id AND p.index_id IN (0,1)), 0)
FROM cdc.change_tables ct
JOIN sys.tables t ON ct.source_object_id = t.object_id
JOIN sys.schemas s ON t.schema_id = s.schema_id
WHERE s.name = '$(SCHEMA_FILTER)'
ORDER BY s.name, t.name;
SQLEOF
)
  query="${query//\$(SCHEMA_FILTER)/$schema}"

  local result
  result=$(SQLCMDPASSWORD="$pass" sqlcmd -S "${host},${port}" -U "$user" -d "$database" -C -h -1 -W -s '|' -Q "$query" 2>&1)

  if [[ $? -ne 0 ]]; then
    echo -e "  ${RED}✗ Query failed${NC}"
    echo -e "  ${GREY}${result}${NC}"
    return 1
  fi

  local count=0
  printf "  ${GREY}%-15s %-30s %-35s %-10s %-20s %12s${NC}\n" "SCHEMA" "TABLE" "CAPTURE_INSTANCE" "NET_CHG" "CDC_ENABLED_AT" "ROW_COUNT"
  printf "  ${GREY}%-15s %-30s %-35s %-10s %-20s %12s${NC}\n" "───────────────" "──────────────────────────────" "───────────────────────────────────" "──────────" "────────────────────" "────────────"

  while IFS='|' read -r col_schema col_table col_instance col_net col_date col_rows; do
    col_schema=$(echo "$col_schema" | xargs)
    col_table=$(echo "$col_table" | xargs)
    col_instance=$(echo "$col_instance" | xargs)
    col_net=$(echo "$col_net" | xargs)
    col_date=$(echo "$col_date" | xargs)
    col_rows=$(echo "$col_rows" | xargs)

    [[ -z "$col_schema" || "$col_schema" == "---"* ]] && continue

    printf "  ${GREEN}●${NC} %-14s %-30s %-35s %-10s %-20s %12s\n" "$col_schema" "$col_table" "$col_instance" "$col_net" "$col_date" "$col_rows"
    ((count++))
  done <<< "$result"

  echo ""
  if [[ $count -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠ No CDC-enabled tables found in schema [${schema}]${NC}"
  else
    echo -e "  ${GREEN}${count} table(s)${NC} with CDC enabled"
  fi

  # Show tables WITHOUT CDC in the same schema (for comparison)
  echo ""
  echo -e "${BOLD}${BLUE}─ Tables Without CDC (schema: ${schema})${NC}"

  local no_cdc_query
  no_cdc_query=$(cat <<'SQLEOF'
SET NOCOUNT ON;
SELECT
    s.name,
    t.name,
    CASE WHEN pk.object_id IS NOT NULL THEN 'Yes' ELSE 'No' END,
    ISNULL((SELECT SUM(p.row_count) FROM sys.dm_db_partition_stats p WHERE p.object_id = t.object_id AND p.index_id IN (0,1)), 0)
FROM sys.tables t
JOIN sys.schemas s ON t.schema_id = s.schema_id
LEFT JOIN cdc.change_tables ct ON ct.source_object_id = t.object_id
LEFT JOIN (
    SELECT DISTINCT parent_object_id AS object_id
    FROM sys.key_constraints WHERE type = 'PK'
) pk ON pk.object_id = t.object_id
WHERE s.name = '$(SCHEMA_FILTER)'
  AND ct.source_object_id IS NULL
  AND t.is_ms_shipped = 0
ORDER BY s.name, t.name;
SQLEOF
)
  no_cdc_query="${no_cdc_query//\$(SCHEMA_FILTER)/$schema}"

  local no_cdc_result
  no_cdc_result=$(SQLCMDPASSWORD="$pass" sqlcmd -S "${host},${port}" -U "$user" -d "$database" -C -h -1 -W -s '|' -Q "$no_cdc_query" 2>&1)

  local no_cdc_count=0
  printf "  ${GREY}%-15s %-30s %-10s %12s${NC}\n" "SCHEMA" "TABLE" "HAS_PK" "ROW_COUNT"
  printf "  ${GREY}%-15s %-30s %-10s %12s${NC}\n" "───────────────" "──────────────────────────────" "──────────" "────────────"

  while IFS='|' read -r col_schema col_table col_pk col_rows; do
    col_schema=$(echo "$col_schema" | xargs)
    col_table=$(echo "$col_table" | xargs)
    col_pk=$(echo "$col_pk" | xargs)
    col_rows=$(echo "$col_rows" | xargs)

    [[ -z "$col_schema" || "$col_schema" == "---"* ]] && continue

    printf "  ${GREY}○${NC} %-14s %-30s %-10s %12s\n" "$col_schema" "$col_table" "$col_pk" "$col_rows"
    ((no_cdc_count++))
  done <<< "$no_cdc_result"

  echo ""
  if [[ $no_cdc_count -eq 0 ]]; then
    echo -e "  ${GREEN}All tables in [${schema}] have CDC enabled${NC}"
  else
    echo -e "  ${GREY}${no_cdc_count} table(s)${NC} without CDC"
  fi

  # CDC capture job info
  echo ""
  echo -e "${BOLD}${BLUE}─ CDC Capture Job${NC}"

  local job_query="SET NOCOUNT ON; EXEC sys.sp_cdc_help_jobs;"
  local job_result
  job_result=$(SQLCMDPASSWORD="$pass" sqlcmd -S "${host},${port}" -U "$user" -d "$database" -C -W -Q "$job_query" 2>&1)
  echo -e "  ${GREY}${job_result}${NC}"
}

# ---------------------------------------------------------------------------
# Aurora PostgreSQL audit
# ---------------------------------------------------------------------------
audit_aurora() {
  local host="${DB_HOST:-${AURORA_HOST:-}}"
  local port="${DB_PORT:-${AURORA_PORT:-5432}}"
  local user="${DB_USER:-${AURORA_USER:-}}"
  local pass="${DB_PASS:-${AURORA_PASSWORD:-}}"
  local database="${DB_NAME:-${AURORA_DATABASE:-}}"
  local schema="${DB_SCHEMA:-public}"
  local publication="${PUB_NAME:-${PG_PUBLICATION_NAME:-cdc_publication}}"

  if [[ -z "$host" || -z "$user" || -z "$pass" || -z "$database" ]]; then
    echo -e "${RED}Error: missing connection details. Set --host/--user/--password/--database or configure .env${NC}"
    exit 1
  fi

  if ! command -v psql &>/dev/null; then
    echo -e "${RED}Error: psql not found. Install with: sudo yum install -y postgresql15 || brew install libpq${NC}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║           Aurora PostgreSQL — CDC Table Audit                 ║${NC}"
  echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${BOLD}${BLUE}─ Connection${NC}"
  echo -e "  Host:        ${host}:${port}"
  echo -e "  Database:    ${database}"
  echo -e "  Schema:      ${schema}"
  echo -e "  User:        ${user}"
  echo -e "  Publication: ${publication}"
  echo ""

  local connstr="host=${host} port=${port} dbname=${database} user=${user}"

  # Check logical replication
  echo -e "${BOLD}${BLUE}─ Logical Replication Status${NC}"

  local wal_level
  wal_level=$(PGPASSWORD="$pass" psql "$connstr" -tAc "SHOW wal_level;" 2>&1)

  if [[ $? -ne 0 ]]; then
    echo -e "  ${RED}✗ Connection failed${NC}"
    echo -e "  ${GREY}${wal_level}${NC}"
    return 1
  fi

  wal_level=$(echo "$wal_level" | xargs)
  if [[ "$wal_level" == "logical" ]]; then
    echo -e "  ${GREEN}✓${NC} wal_level = ${GREEN}logical${NC}"
  else
    echo -e "  ${RED}✗${NC} wal_level = ${RED}${wal_level}${NC} (expected: logical)"
    echo -e "  ${GREY}Set rds.logical_replication = 1 in the cluster parameter group and reboot.${NC}"
  fi

  local rds_logical
  rds_logical=$(PGPASSWORD="$pass" psql "$connstr" -tAc "SHOW rds.logical_replication;" 2>/dev/null || echo "n/a")
  rds_logical=$(echo "$rds_logical" | xargs)
  if [[ "$rds_logical" == "on" ]]; then
    echo -e "  ${GREEN}✓${NC} rds.logical_replication = ${GREEN}on${NC}"
  elif [[ "$rds_logical" == "n/a" ]]; then
    echo -e "  ${GREY}─${NC} rds.logical_replication not available (non-RDS instance)"
  else
    echo -e "  ${RED}✗${NC} rds.logical_replication = ${RED}${rds_logical}${NC}"
  fi
  echo ""

  # Replication slots
  echo -e "${BOLD}${BLUE}─ Replication Slots${NC}"

  local slots
  slots=$(PGPASSWORD="$pass" psql "$connstr" -tA --field-separator='|' -c \
    "SELECT slot_name, plugin, slot_type, CASE WHEN active THEN 'active' ELSE 'inactive' END, restart_lsn FROM pg_replication_slots ORDER BY slot_name;" 2>&1)

  if [[ -z "$slots" || "$slots" == *"(0 rows)"* ]]; then
    echo -e "  ${YELLOW}⚠ No replication slots found${NC}"
    echo -e "  ${GREY}Create with: SELECT pg_create_logical_replication_slot('debezium_cdc', 'pgoutput');${NC}"
  else
    printf "  ${GREY}%-25s %-12s %-10s %-10s %-20s${NC}\n" "SLOT_NAME" "PLUGIN" "TYPE" "STATUS" "RESTART_LSN"
    printf "  ${GREY}%-25s %-12s %-10s %-10s %-20s${NC}\n" "─────────────────────────" "────────────" "──────────" "──────────" "────────────────────"

    while IFS='|' read -r s_name s_plugin s_type s_active s_lsn; do
      [[ -z "$s_name" ]] && continue
      local status_color="$GREEN"
      [[ "$s_active" == "inactive" ]] && status_color="$YELLOW"
      printf "  ${GREEN}●${NC} %-24s %-12s %-10s ${status_color}%-10s${NC} %-20s\n" "$s_name" "$s_plugin" "$s_type" "$s_active" "$s_lsn"
    done <<< "$slots"
  fi
  echo ""

  # Publications
  echo -e "${BOLD}${BLUE}─ Publications${NC}"

  local pubs
  pubs=$(PGPASSWORD="$pass" psql "$connstr" -tA --field-separator='|' -c \
    "SELECT pubname, CASE WHEN puballtables THEN 'ALL TABLES' ELSE 'selected' END FROM pg_publication ORDER BY pubname;" 2>&1)

  if [[ -z "$pubs" ]]; then
    echo -e "  ${YELLOW}⚠ No publications found${NC}"
    echo -e "  ${GREY}Create with: CREATE PUBLICATION ${publication} FOR TABLE <table1>, <table2>;${NC}"
  else
    while IFS='|' read -r p_name p_scope; do
      [[ -z "$p_name" ]] && continue
      local marker="${GREEN}●${NC}"
      [[ "$p_name" != "$publication" ]] && marker="${GREY}○${NC}"
      echo -e "  ${marker} ${p_name} (${p_scope})"
    done <<< "$pubs"
  fi
  echo ""

  # Tables in publication
  echo -e "${BOLD}${BLUE}─ CDC-Enabled Tables (publication: ${publication}, schema: ${schema})${NC}"

  local pub_tables
  pub_tables=$(PGPASSWORD="$pass" psql "$connstr" -tA --field-separator='|' -c \
    "SELECT pt.schemaname, pt.tablename,
            CASE WHEN tc.constraint_type = 'PRIMARY KEY' THEN 'Yes' ELSE 'No' END,
            COALESCE(s.n_live_tup, 0)
     FROM pg_publication_tables pt
     LEFT JOIN information_schema.table_constraints tc
       ON tc.table_schema = pt.schemaname
       AND tc.table_name = pt.tablename
       AND tc.constraint_type = 'PRIMARY KEY'
     LEFT JOIN pg_stat_user_tables s
       ON s.schemaname = pt.schemaname
       AND s.relname = pt.tablename
     WHERE pt.pubname = '${publication}'
       AND pt.schemaname = '${schema}'
     ORDER BY pt.schemaname, pt.tablename;" 2>&1)

  local count=0
  printf "  ${GREY}%-15s %-30s %-10s %12s${NC}\n" "SCHEMA" "TABLE" "HAS_PK" "ROW_COUNT"
  printf "  ${GREY}%-15s %-30s %-10s %12s${NC}\n" "───────────────" "──────────────────────────────" "──────────" "────────────"

  while IFS='|' read -r col_schema col_table col_pk col_rows; do
    [[ -z "$col_schema" ]] && continue
    printf "  ${GREEN}●${NC} %-14s %-30s %-10s %12s\n" "$col_schema" "$col_table" "$col_pk" "$col_rows"
    ((count++))
  done <<< "$pub_tables"

  echo ""
  if [[ $count -eq 0 ]]; then
    echo -e "  ${YELLOW}⚠ No tables in publication [${publication}] for schema [${schema}]${NC}"
  else
    echo -e "  ${GREEN}${count} table(s)${NC} in publication"
  fi

  # Tables NOT in publication
  echo ""
  echo -e "${BOLD}${BLUE}─ Tables Without CDC (schema: ${schema}, not in publication)${NC}"

  local no_pub_tables
  no_pub_tables=$(PGPASSWORD="$pass" psql "$connstr" -tA --field-separator='|' -c \
    "SELECT t.table_schema, t.table_name,
            CASE WHEN tc.constraint_type = 'PRIMARY KEY' THEN 'Yes' ELSE 'No' END,
            COALESCE(s.n_live_tup, 0)
     FROM information_schema.tables t
     LEFT JOIN information_schema.table_constraints tc
       ON tc.table_schema = t.table_schema
       AND tc.table_name = t.table_name
       AND tc.constraint_type = 'PRIMARY KEY'
     LEFT JOIN pg_stat_user_tables s
       ON s.schemaname = t.table_schema
       AND s.relname = t.table_name
     WHERE t.table_schema = '${schema}'
       AND t.table_type = 'BASE TABLE'
       AND NOT EXISTS (
         SELECT 1 FROM pg_publication_tables pt
         WHERE pt.pubname = '${publication}'
           AND pt.schemaname = t.table_schema
           AND pt.tablename = t.table_name
       )
     ORDER BY t.table_schema, t.table_name;" 2>&1)

  local no_pub_count=0
  printf "  ${GREY}%-15s %-30s %-10s %12s${NC}\n" "SCHEMA" "TABLE" "HAS_PK" "ROW_COUNT"
  printf "  ${GREY}%-15s %-30s %-10s %12s${NC}\n" "───────────────" "──────────────────────────────" "──────────" "────────────"

  while IFS='|' read -r col_schema col_table col_pk col_rows; do
    [[ -z "$col_schema" ]] && continue
    printf "  ${GREY}○${NC} %-14s %-30s %-10s %12s\n" "$col_schema" "$col_table" "$col_pk" "$col_rows"
    ((no_pub_count++))
  done <<< "$no_pub_tables"

  echo ""
  if [[ $no_pub_count -eq 0 ]]; then
    echo -e "  ${GREEN}All tables in [${schema}] are in the publication${NC}"
  else
    echo -e "  ${GREY}${no_pub_count} table(s)${NC} not in publication"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "$TARGET" in
  sqlserver) audit_sqlserver ;;
  aurora)    audit_aurora ;;
  both)      audit_sqlserver; audit_aurora ;;
esac

echo ""
echo -e "${BOLD}${BLUE}─ Legend${NC}"
echo -e "  ${GREEN}●${NC} CDC enabled  ${GREY}○${NC} CDC not enabled"
echo ""
