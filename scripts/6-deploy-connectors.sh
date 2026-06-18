#!/bin/bash
# ============================================================
# Phase 6: Deploy CDC Connectors
# ============================================================
# Deploys CDC connectors for forward path, reverse path, or both.
#
# Connectors:
#   Forward path (SQL Server -> Aurora):
#     1. debezium-sqlserver-source  (SQL Server -> Kafka)
#     2. jdbc-sink-aurora           (Kafka -> Aurora PG)
#
#   Reverse path (Aurora -> SQL Server):
#     3. debezium-postgres-source   (Aurora PG -> Kafka)
#     4. jdbc-sink-sqlserver        (Kafka -> SQL Server)
#
# Usage:
#   ./scripts/6-deploy-connectors.sh --forward-only   # Forward path only (SQL Server -> Aurora)
#   ./scripts/6-deploy-connectors.sh --reverse-only   # Reverse path only (Aurora -> SQL Server)
#   ./scripts/6-deploy-connectors.sh --all            # Deploy all 4 connectors
#
# Recommended sequence for new deployments:
#   1. Run --forward-only first — lets Aurora tables be auto-created by jdbc-sink-aurora
#   2. DBA reviews Aurora schema, enables CDC on tables (ALTER PUBLICATION ... ADD TABLE ...)
#   3. Run --reverse-only to activate the reverse path
# ============================================================

set -euo pipefail

# --- Parse flags ---
DEPLOY_FORWARD=false
DEPLOY_REVERSE=false

if [[ $# -eq 0 ]]; then
    echo "[ERROR] A deployment path is required."
    echo ""
    echo "Usage:"
    echo "  $0 --forward-only   # SQL Server -> Aurora (run first for new deployments)"
    echo "  $0 --reverse-only   # Aurora -> SQL Server (run after Aurora tables are ready)"
    echo "  $0 --all            # Deploy all 4 connectors"
    exit 1
fi

for arg in "$@"; do
    case "$arg" in
        --forward-only) DEPLOY_FORWARD=true ;;
        --reverse-only) DEPLOY_REVERSE=true ;;
        --all) DEPLOY_FORWARD=true; DEPLOY_REVERSE=true ;;
        --help|-h)
            sed -n '/^# ====/,/^# ====/p' "$0" | grep "^#" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "[ERROR] Unknown flag: $arg"
            echo "Usage: $0 [--forward-only|--reverse-only|--all]"
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
CONNECTORS_DIR="$SCRIPT_DIR/connectors"
if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] .env not found"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

if ! command -v envsubst &>/dev/null; then
    echo "[ERROR] envsubst not found. Install with: dnf install -y gettext"
    exit 1
fi

CONNECT_FORWARD_URL=${CONNECT_FORWARD_URL:-http://${CONNECT_1_IP:-localhost}:8083}
CONNECT_REVERSE_URL=${CONNECT_REVERSE_URL:-http://${CONNECT_1_IP:-localhost}:8084}

if [[ ! -d "$CONNECTORS_DIR" ]]; then
    echo "[ERROR] Connectors directory not found"
    exit 1
fi

# Verify Connect clusters are accessible
echo "[*] Phase 6: Deploying CDC connectors"
echo "[*] Forward Connect API: $CONNECT_FORWARD_URL"
echo "[*] Reverse Connect API: $CONNECT_REVERSE_URL"

if ! curl -s "$CONNECT_FORWARD_URL/connectors" &>/dev/null; then
    echo "[ERROR] Forward Connect REST API not responding at $CONNECT_FORWARD_URL"
    exit 1
fi
if ! curl -s "$CONNECT_REVERSE_URL/connectors" &>/dev/null; then
    echo "[ERROR] Reverse Connect REST API not responding at $CONNECT_REVERSE_URL"
    exit 1
fi

# Build list of .env variable names for selective envsubst
ENV_VARS=$(grep -E '^[A-Z_][A-Z_0-9]*=' "$ENV_FILE" | cut -d= -f1 | sed 's/^/$/g' | tr '\n' ' ')

deploy_connector() {
    local connector_file="$1"
    local connect_url="$2"
    local connector_name
    connector_name=$(basename "$connector_file" .json)

    echo "[*] Deploying: $connector_name -> $connect_url ..."

    # Delete existing connector if present
    local existing_status
    existing_status=$(curl -s -o /dev/null -w "%{http_code}" "$connect_url/connectors/$connector_name" 2>/dev/null)
    if [[ "$existing_status" == "200" ]]; then
        echo "[*] Connector already exists, deleting..."
        curl -s -X DELETE "$connect_url/connectors/$connector_name" >/dev/null
        sleep 2
    fi

    # Substitute .env variables in JSON, strip empty properties, JSON-escape values
    local resolved_json
    resolved_json=$(python3 -c "
import json, sys, os, re

with open('$connector_file') as f:
    template = f.read()

# Substitute \${VAR} references with env values (undefined vars → empty string)
def replace_var(m):
    return os.environ.get(m.group(1), "")
resolved = re.sub(r'\\\$\{([A-Za-z_][A-Za-z_0-9]*)\}', replace_var, template)

# Escape bare backslashes for valid JSON (e.g., regex values with \\.)
resolved = re.sub(r'(?<!\\\\)\\\\(?![\\\\\"nrtbfu/])', r'\\\\\\\\', resolved)

data = json.loads(resolved)
# Remove empty properties (empty strings, null placeholders) so optional fields don't appear in config
data['config'] = {k: v for k, v in data['config'].items() if v and v.strip()}
print(json.dumps(data))
")

    local http_code response_body
    response_body=$(curl -s -w "\n%{http_code}" -X POST "$connect_url/connectors" \
        -H "Content-Type: application/json" \
        -d "$resolved_json" 2>/dev/null)
    http_code=$(echo "$response_body" | tail -1)
    response_body=$(echo "$response_body" | sed '$d')

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        echo "[OK] $connector_name deployed (HTTP $http_code)"

        # Wait for connector to be in RUNNING state
        sleep 3
        local status
        status=$(curl -s "$connect_url/connectors/$connector_name/status" | grep -o '"state":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo "[*] Status: $status"
    else
        echo "[ERROR] Failed to deploy $connector_name (HTTP $http_code)"

        # Check for common failure reasons and provide helpful guidance
        if echo "$response_body" | grep -q "is invalid.*table\.include\.list.*is already specified"; then
            echo ""
            echo "[!] Conflicting table list configuration"
            echo ""
            echo "Both table.include.list and table.exclude.list cannot be specified simultaneously."
            echo "The script automatically removes empty optional fields from the connector config,"
            echo "but both fields may still be in the JSON template."
            echo ""
            echo "Verify that in .env:"
            echo "  - Either SQLSERVER_TABLE_INCLUDE_LIST or SQLSERVER_TABLE_EXCLUDE_LIST is set (not both)"
            echo "  - Or leave both blank (empty strings get filtered out by the script)"
            echo ""
            return 1
        elif echo "$response_body" | grep -q "does not have access to CDC schema"; then
            echo ""
            echo "[!] CDC not enabled on source tables"
            echo ""
            echo "This error occurs when CDC is disabled on source tables."
            echo ""
            echo "To re-enable CDC and redeploy:"
            echo "  1. Run: ../infra-private/scripts/manage-cdc-tables.sh --enable --sqlserver --tables dbo.<table>"
            echo "     (for reverse path): ../infra-private/scripts/manage-cdc-tables.sh --enable --aurora --tables public.<table>"
            echo "  2. Then run: ./scripts/6-deploy-connectors.sh again"
            echo ""
            return 1
        elif echo "$response_body" | grep -q "replication slot does not exist"; then
            echo ""
            echo "[!] Aurora replication slot missing"
            echo ""
            echo "This error occurs when the Aurora replication slot was dropped."
            echo ""
            echo "To recreate the slot and redeploy:"
            echo "  1. Run: ../infra-private/scripts/reset-databases.sh --aurora"
            echo "  2. Then run: ../infra-private/scripts/manage-cdc-tables.sh --enable --aurora --tables public.<table>"
            echo "  3. Then run: ./scripts/6-deploy-connectors.sh again"
            echo ""
            return 1
        else
            echo ""
            echo "Full error response:"
            echo "$response_body"
            echo ""
            return 1
        fi
    fi
}

if [[ "$DEPLOY_FORWARD" == "true" && "$DEPLOY_REVERSE" == "true" ]]; then
    echo "[*] Mode: all connectors (forward + reverse)"
elif [[ "$DEPLOY_FORWARD" == "true" ]]; then
    echo "[*] Mode: forward path only (SQL Server -> Aurora)"
elif [[ "$DEPLOY_REVERSE" == "true" ]]; then
    echo "[*] Mode: reverse path only (Aurora -> SQL Server)"
fi

echo ""
echo "Step 1/3: Deploying source connectors..."
echo ""

# Sources first — they create CDC topics that sinks subscribe to via topics.regex
if [[ "$DEPLOY_FORWARD" == "true" ]]; then
    deploy_connector "$CONNECTORS_DIR/debezium-sqlserver-source.json" "$CONNECT_FORWARD_URL" || exit 1
fi
if [[ "$DEPLOY_REVERSE" == "true" ]]; then
    deploy_connector "$CONNECTORS_DIR/debezium-postgres-source.json" "$CONNECT_REVERSE_URL" || exit 1
fi

echo ""
echo "Step 2/3: Waiting 15s for source connectors to create CDC topics..."
sleep 15

echo ""
echo "Step 3/3: Deploying sink connectors..."
echo ""

# Sinks after topics exist — topics.regex can match partitions during consumer group join
if [[ "$DEPLOY_FORWARD" == "true" ]]; then
    deploy_connector "$CONNECTORS_DIR/jdbc-sink-aurora.json" "$CONNECT_FORWARD_URL" || exit 1
fi
if [[ "$DEPLOY_REVERSE" == "true" ]]; then
    deploy_connector "$CONNECTORS_DIR/jdbc-sink-sqlserver.json" "$CONNECT_REVERSE_URL" || exit 1
fi

# --- Post-deploy: verify sink partition assignments ---
echo ""
echo "Verifying sink partition assignments..."

verify_sink_partitions() {
    local connector_name="$1"
    local connect_url="$2"
    local max_retries=3
    local retry_delay=10

    for attempt in $(seq 1 $max_retries); do
        local status_json
        status_json=$(curl -s "$connect_url/connectors/$connector_name/status" 2>/dev/null)
        local task_count
        task_count=$(echo "$status_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
running = [t for t in data.get('tasks', []) if t['state'] == 'RUNNING']
print(len(running))
" 2>/dev/null || echo "0")

        if [[ "$task_count" -gt 0 ]]; then
            echo "[OK] $connector_name: $task_count task(s) RUNNING"
            return 0
        fi

        if [[ $attempt -lt $max_retries ]]; then
            echo "[WARN] $connector_name: no running tasks (attempt $attempt/$max_retries) — restarting..."
            curl -s -X POST "$connect_url/connectors/$connector_name/restart?includeTasks=true" >/dev/null 2>&1
            sleep $retry_delay
        fi
    done

    echo "[WARN] $connector_name: could not verify running tasks after $max_retries attempts"
    return 1
}

SINK_WARNINGS=0
[[ "$DEPLOY_FORWARD" == "true" ]] && { verify_sink_partitions "jdbc-sink-aurora" "$CONNECT_FORWARD_URL" || SINK_WARNINGS=$((SINK_WARNINGS + 1)); }
[[ "$DEPLOY_REVERSE" == "true" ]] && { verify_sink_partitions "jdbc-sink-sqlserver" "$CONNECT_REVERSE_URL" || SINK_WARNINGS=$((SINK_WARNINGS + 1)); }

echo ""
if [[ $SINK_WARNINGS -gt 0 ]]; then
    echo "[WARN] $SINK_WARNINGS sink(s) may need manual verification"
else
    echo "[OK] All sink connectors verified with running tasks"
fi

echo ""
echo "[*] Phase 6 diagnostics..."
echo "  Deployed connectors:"

# Forward path connectors (port 8083)
echo "    Forward path (8083):"
connectors_fwd=$(curl -s "http://${CONNECT_1_IP}:8083/connectors" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | sort)
if [[ -n "$connectors_fwd" ]]; then
    echo "$connectors_fwd" | while read c; do
        echo "      ✅ $c"
    done
else
    echo "      ⚠️  No connectors found"
fi

# Reverse path connectors (port 8084)
echo "    Reverse path (8084):"
connectors_rev=$(curl -s "http://${CONNECT_1_IP}:8084/connectors" 2>/dev/null | grep -o '"[^"]*"' | tr -d '"' | sort)
if [[ -n "$connectors_rev" ]]; then
    echo "$connectors_rev" | while read c; do
        echo "      ✅ $c"
    done
else
    echo "      ⚠️  No connectors found"
fi

echo ""
total_connectors=$(($(echo "$connectors_fwd" | wc -l) + $(echo "$connectors_rev" | wc -l)))
echo "[OK] All $total_connectors connectors deployed"
echo ""
echo "Verify connector status:"
echo "  Forward: curl http://${CONNECT_1_IP}:8083/connectors?expand=status"
echo "  Reverse: curl http://${CONNECT_1_IP}:8084/connectors?expand=status"
echo ""
echo "Next: ./scripts/7-validate-deployment.sh (validate end-to-end CDC)"
