#!/usr/bin/env bash
#
# deploy-all-connectors.sh
#
# Deploys all CDC connectors to the two Kafka Connect clusters via REST API.
# Forward connectors go to Connect Worker 1 (port 8083).
# Reverse connectors go to Connect Worker 2 (port 8084).
# Substitutes environment variables in connector JSON configs before deploying.
#
# CUSTOMIZE: The connector JSON files contain example values that may need adjustment:
#   - message.key.columns in source connectors references an example no-PK table.
#     Update to match your own no-PK tables and their key columns.
#   - Loop-prevention headers (__cdc_from_sqlserver, __cdc_from_aurora) and DLQ topic
#     names (dlq-jdbc-sink-*) are hardcoded but generally don't need changing.
#
# Prerequisites:
#   - curl, jq, and envsubst (gettext) must be installed
#   - Required environment variables must be set (or loaded from .env):
#       SQLSERVER_HOST, SQLSERVER_PORT, SQLSERVER_DATABASE,
#       AURORA_HOST, AURORA_PORT, AURORA_DATABASE,
#       SQLSERVER_USER, SQLSERVER_PASSWORD, AURORA_USER, AURORA_PASSWORD,
#       CDC_READER_USER, CDC_READER_PASSWORD (Aurora sink only),
#       BROKER_1_IP, BROKER_2_IP, BROKER_3_IP, CONNECT_1_IP
#
# Usage:
#   export CONNECT_FORWARD_URL=http://<connect-node>:8083
#   export CONNECT_REVERSE_URL=http://<connect-node>:8084
#   ./connectors/deploy-all-connectors.sh
#
set -euo pipefail

# Load and export all environment variables from .env
if [ -f ".env" ]; then
  set -a
  source ".env"
  set +a
fi

# Pre-flight: check required commands
for cmd in curl jq envsubst; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command '$cmd' not found."
    if [[ "$cmd" == "envsubst" ]]; then
      echo "Install with: sudo apt-get install gettext  (Ubuntu/Debian)"
      echo "           or: sudo yum install gettext     (Amazon Linux/RHEL)"
    fi
    exit 1
  fi
done

CONNECT_FORWARD_URL="${CONNECT_FORWARD_URL:-http://localhost:8083}"
CONNECT_REVERSE_URL="${CONNECT_REVERSE_URL:-http://localhost:8084}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Forward path: SQL Server -> Kafka -> Aurora (deployed to Connect Worker 1)
FORWARD_CONNECTORS=(
  "debezium-sqlserver-source"
  "jdbc-sink-aurora"
)

# Reverse path: Aurora -> Kafka -> SQL Server (deployed to Connect Worker 2)
REVERSE_CONNECTORS=(
  "debezium-postgres-source"
  "jdbc-sink-sqlserver"
)

# --------------------------------------------------------------------------
# Wait for Kafka Connect REST API to become available
# --------------------------------------------------------------------------
wait_for_connect() {
  local url="$1" label="$2"
  local max_attempts=60
  local attempt=1
  echo "Waiting for ${label} at ${url} ..."
  while [ $attempt -le $max_attempts ]; do
    if curl -sf -o /dev/null "${url}/connectors"; then
      echo "${label} is ready."
      return 0
    fi
    echo "  Attempt ${attempt}/${max_attempts} — ${label} not ready yet, retrying in 5s ..."
    sleep 5
    attempt=$((attempt + 1))
  done
  echo "ERROR: ${label} did not become ready after $((max_attempts * 5))s."
  exit 1
}

# --------------------------------------------------------------------------
# Deploy a single connector using PUT (create or update)
# --------------------------------------------------------------------------
deploy_connector() {
  local name="$1"
  local connect_url="$2"
  local json_file="${SCRIPT_DIR}/${name}.json"

  if [ ! -f "$json_file" ]; then
    echo "ERROR: Connector config not found: ${json_file}"
    return 1
  fi

  echo ""
  echo "------------------------------------------------------------"
  echo "Deploying connector: ${name} -> ${connect_url}"
  echo "------------------------------------------------------------"

  # Substitute only known environment variables (not $Value, $Key, $1, etc.)
  local envvars='$SQLSERVER_HOST $SQLSERVER_PORT $SQLSERVER_DATABASE $SQLSERVER_USER $SQLSERVER_PASSWORD
    $AURORA_HOST $AURORA_PORT $AURORA_DATABASE $AURORA_USER $AURORA_PASSWORD
    $CDC_READER_USER $CDC_READER_PASSWORD
    $BROKER_1_IP $BROKER_2_IP $BROKER_3_IP $CONNECT_1_IP $MONITOR_1_IP
    $SQLSERVER_TOPIC_PREFIX $SQLSERVER_TABLE_INCLUDE_LIST $SQLSERVER_SCHEMA_HISTORY_TOPIC
    $AURORA_TOPIC_PREFIX $AURORA_SCHEMA_INCLUDE_LIST $AURORA_TABLE_INCLUDE_LIST $AURORA_SCHEMA_HISTORY_TOPIC
    $PG_SLOT_NAME $PG_PUBLICATION_NAME
    $JDBC_SINK_AURORA_TOPICS $JDBC_SINK_AURORA_TOPIC_REGEX
    $JDBC_SINK_SQLSERVER_TOPICS $JDBC_SINK_SQLSERVER_TOPIC_REGEX
    $KAFKA_REPLICATION_FACTOR $KAFKA_DEFAULT_PARTITIONS $KAFKA_TOPIC_RETENTION_MS
    $DEBEZIUM_SNAPSHOT_MODE $SCHEMA_REGISTRY_PORT
    $JDBC_SINK_AURORA_TASKS_MAX $JDBC_SINK_SQLSERVER_TASKS_MAX'
  local config
  config=$(envsubst "$envvars" < "$json_file" | jq '.config')

  # PUT /connectors/{name}/config — creates if not exists, updates if exists
  local http_code
  http_code=$(curl -s -o /tmp/deploy_response.json -w "%{http_code}" \
    -X PUT \
    -H "Content-Type: application/json" \
    -d "$config" \
    "${connect_url}/connectors/${name}/config")

  if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
    echo "  Deployed successfully (HTTP ${http_code})."
  else
    echo "  WARNING: Unexpected response (HTTP ${http_code}):"
    jq '.' /tmp/deploy_response.json 2>/dev/null || cat /tmp/deploy_response.json
  fi

  # Brief pause to let the connector initialize
  sleep 2

  # Print connector status
  echo "  Status:"
  curl -s "${connect_url}/connectors/${name}/status" | jq '.' 2>/dev/null || echo "  (could not retrieve status)"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
wait_for_connect "${CONNECT_FORWARD_URL}" "Connect Worker 1 (forward)"
wait_for_connect "${CONNECT_REVERSE_URL}" "Connect Worker 2 (reverse)"

echo ""
echo "============================================================"
echo "Deploying forward connectors to ${CONNECT_FORWARD_URL}"
echo "============================================================"

for connector in "${FORWARD_CONNECTORS[@]}"; do
  deploy_connector "$connector" "${CONNECT_FORWARD_URL}"
done

echo ""
echo "============================================================"
echo "Deploying reverse connectors to ${CONNECT_REVERSE_URL}"
echo "============================================================"

for connector in "${REVERSE_CONNECTORS[@]}"; do
  deploy_connector "$connector" "${CONNECT_REVERSE_URL}"
done

echo ""
echo "============================================================"
echo "All connectors deployed. Summary:"
echo "============================================================"
echo ""
echo "Forward cluster (${CONNECT_FORWARD_URL}):"
curl -s "${CONNECT_FORWARD_URL}/connectors" | jq '.'
echo ""
echo "Reverse cluster (${CONNECT_REVERSE_URL}):"
curl -s "${CONNECT_REVERSE_URL}/connectors" | jq '.'
echo ""
echo "To check individual status:"
echo "  curl ${CONNECT_FORWARD_URL}/connectors/<name>/status | jq ."
echo "  curl ${CONNECT_REVERSE_URL}/connectors/<name>/status | jq ."
