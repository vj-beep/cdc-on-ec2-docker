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

    # Substitute only .env variables in JSON (leave $1 etc. intact)
    local resolved_json
    resolved_json=$(envsubst "$ENV_VARS" < "$connector_file")

    # Strip properties with empty values (e.g., message.key.columns when no no-PK tables)
    resolved_json=$(echo "$resolved_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
data['config'] = {k: v for k, v in data['config'].items() if v != ''}
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
        echo "$response_body" | head -5
        return 1
    fi
}

echo ""
echo "Deploying forward path connectors (Connect-1 :8083)..."
echo ""

# Forward path: SQL Server -> Kafka -> Aurora
deploy_connector "$CONNECTORS_DIR/debezium-sqlserver-source.json" "$CONNECT_FORWARD_URL" || exit 1
deploy_connector "$CONNECTORS_DIR/jdbc-sink-aurora.json" "$CONNECT_FORWARD_URL" || exit 1

echo ""
echo "Deploying reverse path connectors (Connect-2 :8084)..."
echo ""

# Reverse path: Aurora -> Kafka -> SQL Server
deploy_connector "$CONNECTORS_DIR/debezium-postgres-source.json" "$CONNECT_REVERSE_URL" || exit 1
deploy_connector "$CONNECTORS_DIR/jdbc-sink-sqlserver.json" "$CONNECT_REVERSE_URL" || exit 1

echo ""
echo "[OK] All 4 connectors deployed"
echo ""
echo "Verify connector status:"
echo "  Forward: curl http://${CONNECT_1_IP}:8083/connectors?expand=status"
echo "  Reverse: curl http://${CONNECT_1_IP}:8084/connectors?expand=status"
echo ""
echo "Next: ./scripts/7-validate-poc.sh (validate end-to-end CDC)"
