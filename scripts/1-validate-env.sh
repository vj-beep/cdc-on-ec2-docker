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

# Determine dispatch mode — instance IDs only required for SSM
DISPATCH_MODE="${DISPATCH_MODE:-ssm}"

# Required variables
REQUIRED_VARS=(
    "PUBLIC_REPO_URL"
    "BROKER_1_IP"
    "BROKER_2_IP"
    "BROKER_3_IP"
    "CONNECT_1_IP"
    "MONITOR_1_IP"
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

# Instance IDs only required for SSM dispatch
INSTANCE_ID_VARS=(
    "BROKER_1_INSTANCE_ID"
    "BROKER_2_INSTANCE_ID"
    "BROKER_3_INSTANCE_ID"
    "CONNECT_1_INSTANCE_ID"
    "MONITOR_1_INSTANCE_ID"
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
    echo "   ./scripts/1-validate-env.sh"
    exit 1
else
    echo "✅ All required variables set"
fi

# Check instance IDs — required for SSM, optional for SSH
echo ""
if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    echo "ℹ️  DISPATCH_MODE=ssh — instance IDs not required (scripts use *_IP vars)"
    for var in "${INSTANCE_ID_VARS[@]}"; do
        if [[ -z "${!var}" ]]; then
            echo "  ⚠️  $var = (not set — OK for ssh mode)"
        else
            echo "  ✅ $var = ${!var}"
        fi
    done
    # Validate SSH_KEY_PATH is set
    if [[ -z "${SSH_KEY_PATH:-}" ]]; then
        echo "  ❌ Missing: SSH_KEY_PATH (required when DISPATCH_MODE=ssh)"
        ((MISSING++))
    else
        echo "  ✅ SSH_KEY_PATH = ${SSH_KEY_PATH}"
    fi
else
    echo "ℹ️  DISPATCH_MODE=ssm — validating instance IDs..."
    for var in "${INSTANCE_ID_VARS[@]}"; do
        if [[ -z "${!var}" ]]; then
            echo "  ❌ Missing: $var"
            ((MISSING++))
        else
            echo "  ✅ $var = ${!var}"
        fi
    done
fi

if [[ $MISSING -gt 0 ]]; then
    echo ""
    echo "❌ ERROR: $MISSING variable(s) missing after instance ID check"
    exit 1
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
