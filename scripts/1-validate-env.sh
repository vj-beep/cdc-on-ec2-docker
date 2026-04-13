#!/bin/bash
# ============================================================
# Validate that all required environment variables are set
# ============================================================
# Call before deployment to catch missing credentials early.
#
# Usage: ./scripts/1-validate-env.sh
# ============================================================

set -e

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR" || exit 1

# Source .env if it exists
if [[ -f .env ]]; then
    source .env
else
    echo "❌ ERROR: .env file not found"
    echo ""
    echo "Create one from template:"
    echo "   cp .env.template .env"
    echo "   # Edit .env with your values"
    echo "   ./scripts/validate-env.sh"
    exit 1
fi

# Required variables
REQUIRED_VARS=(
    "PUBLIC_REPO_URL"
    "BROKER_1_IP"
    "BROKER_2_IP"
    "BROKER_3_IP"
    "CONNECT_1_IP"
    "MONITOR_1_IP"
    "BROKER_1_INSTANCE_ID"
    "BROKER_2_INSTANCE_ID"
    "BROKER_3_INSTANCE_ID"
    "CONNECT_1_INSTANCE_ID"
    "MONITOR_1_INSTANCE_ID"
    "AURORA_HOST"
    "AURORA_PORT"
    "AURORA_DATABASE"
    "AURORA_USER"
    "AURORA_PASSWORD"
    "SQLSERVER_HOST"
    "SQLSERVER_PORT"
    "SQLSERVER_DATABASE"
    "SQLSERVER_USER"
    "SQLSERVER_PASSWORD"
    "CDC_READER_USER"
    "CDC_READER_PASSWORD"
    "CP_VERSION"
    "CLUSTER_ID"
    "KAFKA_REPLICATION_FACTOR"
)

echo ""
echo "🔍 Validating environment variables..."
echo ""

MISSING=0

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "  ❌ Missing: $var"
        ((MISSING++))
    else
        # Mask passwords in output
        if [[ "$var" == *"PASSWORD" ]]; then
            echo "  ✅ $var = ***"
        else
            echo "  ✅ $var = ${!var}"
        fi
    fi
done

echo ""

if [[ $MISSING -gt 0 ]]; then
    echo "❌ ERROR: $MISSING required variables missing"
    echo ""
    echo "Edit .env and fill in all values:"
    echo "   vim .env"
    echo "   ./scripts/validate-env.sh"
    exit 1
else
    echo "✅ All required variables set"
fi

# Advisory checks (non-blocking warnings)
WARNINGS=0

# Warn if message.key.columns is empty — required for tables without primary keys
if [[ -z "${SQLSERVER_MESSAGE_KEY_COLUMNS:-}" && -z "${AURORA_MESSAGE_KEY_COLUMNS:-}" ]]; then
    echo ""
    echo "  ⚠️  SQLSERVER_MESSAGE_KEY_COLUMNS and AURORA_MESSAGE_KEY_COLUMNS are both empty"
    echo "     If any CDC tables lack a primary key, Debezium will produce null-key records"
    echo "     and JDBC sink connectors (pk.mode=record_key) will fail."
    echo "     Format: <database>.<schema>.<table>:<col1>,<col2>"
    echo "     Example: yourdb.dbo.audit_log:event_timestamp,source_type"
    echo "     Leave empty ONLY if all your tables have primary keys."
    ((WARNINGS++))
fi

echo ""
if [[ $WARNINGS -gt 0 ]]; then
    echo "✅ All required variables set ($WARNINGS advisory warning(s) above)"
else
    echo "✅ All required variables set"
fi
echo ""
echo "Ready for deployment!"
exit 0
