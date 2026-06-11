#!/bin/bash
# ============================================================
# Inspect SqlServerCaseRestorer SMT Schema Cache
# ============================================================
# Shows what table and column metadata the SMT has loaded in memory
# (simulates the SMT's schema discovery and caching)
#
# Usage: ./scripts/inspect-smt-schema-cache.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] .env not found at $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"

# The SMT reads schema info for the configured table schema (typically 'dbo')
SMT_TABLE_SCHEMA="${SMT_TABLE_SCHEMA:-dbo}"

echo "=========================================================="
echo "SqlServerCaseRestorer SMT — Schema Cache Inspection"
echo "=========================================================="
echo ""
echo "Configuration:"
echo "  JDBC URL: jdbc:sqlserver://${SQLSERVER_HOST}:${SQLSERVER_PORT};databaseName=${SQLSERVER_DATABASE}"
echo "  Schema:   $SMT_TABLE_SCHEMA"
echo ""
echo "=========================================================="

# Query SQL Server for the schema that the SMT loads
SQLCMDPASSWORD="$SQLSERVER_PASSWORD" sqlcmd \
    -S "$SQLSERVER_HOST","$SQLSERVER_PORT" \
    -U "$SQLSERVER_USER" \
    -d "$SQLSERVER_DATABASE" \
    -C \
    << 'EOF'

-- Tables and columns in the SMT schema cache
SET NOCOUNT ON;

DECLARE @SCHEMA NVARCHAR(128) = 'dbo';

-- Column name mapping (what SMT sees: lowercase columns)
SELECT
  t.TABLE_SCHEMA,
  t.TABLE_NAME,
  c.COLUMN_NAME,
  c.DATA_TYPE,
  c.IS_NULLABLE,
  CASE WHEN tc.CONSTRAINT_TYPE = 'PRIMARY KEY' THEN 'PK' ELSE '' END AS PK
FROM INFORMATION_SCHEMA.TABLES t
LEFT JOIN INFORMATION_SCHEMA.COLUMNS c
  ON t.TABLE_SCHEMA = c.TABLE_SCHEMA
  AND t.TABLE_NAME = c.TABLE_NAME
LEFT JOIN INFORMATION_SCHEMA.KEY_COLUMN_USAGE kcu
  ON c.TABLE_SCHEMA = kcu.TABLE_SCHEMA
  AND c.TABLE_NAME = kcu.TABLE_NAME
  AND c.COLUMN_NAME = kcu.COLUMN_NAME
LEFT JOIN INFORMATION_SCHEMA.TABLE_CONSTRAINTS tc
  ON kcu.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
WHERE t.TABLE_SCHEMA = @SCHEMA
  AND t.TABLE_TYPE = 'BASE TABLE'
ORDER BY
  t.TABLE_NAME,
  c.ORDINAL_POSITION;

EOF

echo ""
echo "=========================================================="
echo "SMT Behavior:"
echo "  - Caches all tables in schema '$SMT_TABLE_SCHEMA' at startup"
echo "  - For each table, records all column names (exact case)"
echo "  - When processing records, transforms Kafka field names"
echo "    from lowercase to SQL Server exact case"
echo "  - Example: 'title' (Kafka) → 'title' (SQL Server)"
echo "=========================================================="
