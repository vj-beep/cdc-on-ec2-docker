#!/bin/bash
# ============================================================
# Phase 6: Deploy CDC Connectors
# ============================================================
# Deploys all 4 CDC connectors (forward + reverse paths)
#
# Connectors deployed:
#   1. debezium-sqlserver-source  (SQL Server -> Kafka)
#   2. jdbc-sink-aurora           (Kafka -> Aurora PG)
#   3. debezium-postgres-source   (Aurora PG -> Kafka)
#   4. jdbc-sink-sqlserver        (Kafka -> SQL Server)
#
# Prerequisites:
#   - All services running (brokers, Connect, Schema Registry)
#   - Phase 5 (start services) complete — all brokers and Connect workers running
#
# Usage: ./scripts/6-deploy-connectors.sh
# ============================================================

set -euo pipefail

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
            echo "This error occurs when CDC is disabled on source tables (e.g., after --forward-path reset)."
            echo ""
            echo "To re-enable CDC and redeploy:"
            echo "  1. Run: ../infra-private/scripts/reset-databases.sh"
            echo "  2. Select option 9 (forward path) or 10 (reverse path) to re-enable CDC"
            echo "  3. Then run: ./scripts/6-deploy-connectors.sh again"
            echo ""
            return 1
        elif echo "$response_body" | grep -q "replication slot does not exist"; then
            echo ""
            echo "[!] Aurora replication slot missing"
            echo ""
            echo "This error occurs when the replication slot was dropped (e.g., after --reverse-path reset)."
            echo ""
            echo "To recreate the slot and redeploy:"
            echo "  1. Run: ../infra-private/scripts/reset-databases.sh"
            echo "  2. Select option 10 (reverse path) to recreate slot/publication"
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

echo ""
echo "Step 1/3: Deploying source connectors (both paths)..."
echo ""

# Sources first — they create CDC topics that sinks subscribe to via topics.regex
deploy_connector "$CONNECTORS_DIR/debezium-sqlserver-source.json" "$CONNECT_FORWARD_URL" || exit 1
deploy_connector "$CONNECTORS_DIR/debezium-postgres-source.json" "$CONNECT_REVERSE_URL" || exit 1

echo ""
echo "Step 2/3: Waiting 15s for source connectors to create CDC topics..."
sleep 15

echo ""
echo "Step 3/3: Deploying sink connectors (both paths)..."
echo ""

# Sinks after topics exist — topics.regex can match partitions during consumer group join
deploy_connector "$CONNECTORS_DIR/jdbc-sink-aurora.json" "$CONNECT_FORWARD_URL" || exit 1
deploy_connector "$CONNECTORS_DIR/jdbc-sink-sqlserver.json" "$CONNECT_REVERSE_URL" || exit 1

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
verify_sink_partitions "jdbc-sink-aurora" "$CONNECT_FORWARD_URL" || SINK_WARNINGS=$((SINK_WARNINGS + 1))
verify_sink_partitions "jdbc-sink-sqlserver" "$CONNECT_REVERSE_URL" || SINK_WARNINGS=$((SINK_WARNINGS + 1))

echo ""
if [[ $SINK_WARNINGS -gt 0 ]]; then
    echo "[WARN] $SINK_WARNINGS sink(s) may need manual verification"
else
    echo "[OK] All sink connectors verified with running tasks"
fi

echo ""
echo "[OK] All 4 connectors deployed"
echo ""
echo "Verify connector status:"
echo "  Forward: curl http://${CONNECT_1_IP}:8083/connectors?expand=status"
echo "  Reverse: curl http://${CONNECT_1_IP}:8084/connectors?expand=status"
echo ""
echo "Next: ./scripts/7-validate-poc.sh (validate end-to-end CDC)"
