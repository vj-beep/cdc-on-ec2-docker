#!/usr/bin/env bash
# =============================================================================
# 7-validate-poc.sh — Infrastructure Validation for CDC deployment
#
# Validates infrastructure readiness and service health:
#   - Infrastructure connectivity (brokers, Connect, Schema Registry, DBs)
#   - Connector health (state, task status)
#   - Schema Registry
#   - DLQ topics (should be empty)
#   - Consumer lag
#
# NOTE: Data path tests (forward/reverse CDC, loop prevention) are NOT
# included here — they require customer-specific table configuration.
# Set VALIDATE_* variables in .env and use a separate data validation script.
#
# Usage:
#   ./scripts/7-validate-poc.sh
#
# Requires: Environment variables set (from .env) or passed directly.
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

pass()  { echo -e "  ${GREEN}[PASS]${NC}  $*"; }
fail()  { echo -e "  ${RED}[FAIL]${NC}  $*"; FAILURES=$((FAILURES + 1)); }
warn()  { echo -e "  ${YELLOW}[WARN]${NC}  $*"; WARNINGS=$((WARNINGS + 1)); }
info()  { echo -e "  ${CYAN}[INFO]${NC}  $*"; }
section() { echo -e "\n${BOLD}--- $* ---${NC}"; }

FAILURES=0
WARNINGS=0

# ---------------------------------------------------------------------------
# Load .env if present
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [[ -f "${REPO_ROOT}/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "${REPO_ROOT}/.env"
    set +a
fi

# ---------------------------------------------------------------------------
# Required environment variables
# ---------------------------------------------------------------------------
REQUIRED_VARS=(
    BROKER_1_IP
    BROKER_2_IP
    BROKER_3_IP
    CONNECT_1_IP
    SQLSERVER_HOST
    SQLSERVER_PORT
    SQLSERVER_USER
    SQLSERVER_PASSWORD
    SQLSERVER_DATABASE
    AURORA_HOST
    AURORA_PORT
    AURORA_USER
    AURORA_PASSWORD
    AURORA_DATABASE
)

section "Checking Required Environment Variables"

MISSING_VARS=0
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        fail "Missing environment variable: ${var}"
        MISSING_VARS=$((MISSING_VARS + 1))
    else
        pass "${var} is set"
    fi
done

if [[ ${MISSING_VARS} -gt 0 ]]; then
    echo -e "\n${RED}${MISSING_VARS} required variable(s) missing. Set them in .env or export before running.${NC}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Pre-Flight Checks (infrastructure readiness)
# ---------------------------------------------------------------------------
section "Pre-Flight Infrastructure Checks"

# Check Node Distribution (verify services on correct nodes)
section "Node Distribution Validation"
check_node_distribution() {
    # Verify brokers 1-3 have NO connect services
    for broker_ip in "${BROKER_1_IP:-}" "${BROKER_2_IP:-}" "${BROKER_3_IP:-}"; do
        if [[ -z "$broker_ip" ]]; then continue; fi
        if docker -H "ssh://ec2-user@$broker_ip" ps 2>/dev/null | grep -q "connect\|schema-registry\|control-center\|ksqldb\|prometheus\|grafana"; then
            fail "Broker node $broker_ip has non-broker services (should only have broker, node-exporter, cadvisor)"
        else
            pass "Broker node $broker_ip has correct service distribution"
        fi
    done

    # Verify Connect node (CONNECT_1_IP) has no broker services
    if [[ -n "${CONNECT_1_IP:-}" ]]; then
        if docker -H "ssh://ec2-user@$CONNECT_1_IP" ps 2>/dev/null | grep -q "^.*_broker-[0-9]"; then
            fail "Connect node $CONNECT_1_IP has broker services (should only have connect, schema-registry, node-exporter, cadvisor)"
        else
            pass "Connect node $CONNECT_1_IP has correct service distribution"
        fi
    fi
}

# Only run if SSH/Docker access available; skip on jumpbox-only deployments
if command -v docker &>/dev/null && docker -H "ssh://ec2-user@${BROKER_1_IP:-localhost}" ps &>/dev/null 2>&1; then
    check_node_distribution
else
    info "Skipping node distribution check (SSH/Docker to nodes not available from jumpbox)"
fi

# Check Kafka data directory on local node (if applicable)
KAFKA_DATA_DIR="${KAFKA_DATA_DIR:-/data/kafka}"
if [[ -d "$KAFKA_DATA_DIR" ]]; then
    pass "$KAFKA_DATA_DIR mount exists"
    MOUNT_STATS=$(df "$KAFKA_DATA_DIR" | tail -1 | awk '{printf "Used: %s, Available: %s", $3, $4}')
    info "  $MOUNT_STATS"
else
    warn "$KAFKA_DATA_DIR mount not found (expected on broker nodes, OK on jumpbox)"
fi

# Check Docker daemon
if command -v docker &>/dev/null; then
    if docker ps &>/dev/null; then
        pass "Docker daemon is running"
    else
        fail "Docker daemon not responding (try: systemctl start docker)"
    fi
else
    warn "Docker not installed (expected on jumpbox only)"
fi

# Check JDBC driver for Connect node (if we can access repo)
if compgen -G "${REPO_ROOT}/connect/jars/mssql-jdbc-*.jar" >/dev/null 2>&1; then
    JDBC_JAR=$(ls -1 "${REPO_ROOT}/connect/jars/mssql-jdbc-"*.jar 2>/dev/null | head -1)
    if [[ -n "$JDBC_JAR" ]]; then
        JDBC_SIZE=$(du -h "$JDBC_JAR" | cut -f1)
        pass "JDBC driver present (${JDBC_SIZE}): $(basename "$JDBC_JAR")"
    fi
else
    warn "JDBC driver not found in ${REPO_ROOT}/connect/jars/ (expected on Node 4 before build)"
fi

# Check network tools
for tool in nc curl jq; do
    if command -v "$tool" &>/dev/null; then
        pass "Utility '$tool' available"
    else
        fail "Utility '$tool' not found (required for validation)"
    fi
done

# Defaults
SCHEMA_REGISTRY_PORT="${SCHEMA_REGISTRY_PORT:-8081}"
KAFKA_PORT="${KAFKA_PORT:-9092}"

# Both Connect workers run on Node 4 (CONNECT_1_IP) with separate ports
CONNECT_WORKER_1_IP="${CONNECT_1_IP}"
CONNECT_WORKER_1_PORT="8083"
CONNECT_WORKER_2_IP="${CONNECT_1_IP}"
CONNECT_WORKER_2_PORT="8084"

# ---------------------------------------------------------------------------
# Helper: TCP connectivity check
# ---------------------------------------------------------------------------
check_tcp() {
    local host="$1" port="$2" label="$3" timeout="${4:-5}"
    if nc -z -w "${timeout}" "${host}" "${port}" 2>/dev/null; then
        pass "${label} (${host}:${port}) is reachable"
        return 0
    else
        fail "${label} (${host}:${port}) is NOT reachable"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: HTTP check
# ---------------------------------------------------------------------------
check_http() {
    local url="$1" label="$2" timeout="${3:-10}"
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --max-time "${timeout}" "${url}" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" =~ ^2[0-9]{2}$ ]]; then
        pass "${label} (${url}) returned HTTP ${HTTP_CODE}"
        return 0
    else
        fail "${label} (${url}) returned HTTP ${HTTP_CODE}"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# 1. Infrastructure Connectivity
# ---------------------------------------------------------------------------
section "Infrastructure Connectivity"

# Kafka brokers
check_tcp "${BROKER_1_IP}" "${KAFKA_PORT}" "Kafka Broker 1"
check_tcp "${BROKER_2_IP}" "${KAFKA_PORT}" "Kafka Broker 2"
check_tcp "${BROKER_3_IP}" "${KAFKA_PORT}" "Kafka Broker 3"

# Connect workers (both on Node 4, different ports)
check_tcp "${CONNECT_WORKER_1_IP}" "${CONNECT_WORKER_1_PORT}" "Connect Worker 1 (forward)"
check_tcp "${CONNECT_WORKER_2_IP}" "${CONNECT_WORKER_2_PORT}" "Connect Worker 2 (reverse)"

# Schema Registry (Node 4)
check_tcp "${CONNECT_1_IP}" "${SCHEMA_REGISTRY_PORT}" "Schema Registry"

# Databases
check_tcp "${SQLSERVER_HOST}" "${SQLSERVER_PORT}" "SQL Server"
check_tcp "${AURORA_HOST}" "${AURORA_PORT}" "Aurora PostgreSQL"

# ---------------------------------------------------------------------------
# 2. Kafka Broker Health
# ---------------------------------------------------------------------------
section "Kafka Broker Health"

BOOTSTRAP="${BROKER_1_IP}:${KAFKA_PORT}"

# Try to list topics as a broker health check
if docker exec -t "$(docker ps -q -f name=broker --no-trunc 2>/dev/null | head -1)" \
    kafka-topics --bootstrap-server "${BOOTSTRAP}" --list >/dev/null 2>&1; then
    TOPIC_COUNT=$(docker exec -t "$(docker ps -q -f name=broker --no-trunc 2>/dev/null | head -1)" \
        kafka-topics --bootstrap-server "${BOOTSTRAP}" --list 2>/dev/null | wc -l)
    pass "Kafka cluster is healthy (${TOPIC_COUNT} topics)"
elif command -v kafka-topics &>/dev/null; then
    TOPIC_COUNT=$(kafka-topics --bootstrap-server "${BOOTSTRAP}" --list 2>/dev/null | wc -l)
    pass "Kafka cluster is healthy (${TOPIC_COUNT} topics)"
else
    # Fallback: use the TCP check result from above
    if nc -z -w 5 "${BROKER_1_IP}" "${KAFKA_PORT}" 2>/dev/null; then
        pass "Kafka broker port is open (install kafka-topics CLI for deeper checks)"
    else
        fail "Cannot verify Kafka cluster health"
    fi
fi

# ---------------------------------------------------------------------------
# 3. Connect Worker Health
# ---------------------------------------------------------------------------
section "Connect Workers & Connectors"

check_http "http://${CONNECT_WORKER_1_IP}:${CONNECT_WORKER_1_PORT}/" "Connect Worker 1 (forward) REST API"
check_http "http://${CONNECT_WORKER_2_IP}:${CONNECT_WORKER_2_PORT}/" "Connect Worker 2 (reverse) REST API"

# List connectors from both clusters
CONNECTORS_JSON=$(curl -s --max-time 10 "http://${CONNECT_WORKER_1_IP}:${CONNECT_WORKER_1_PORT}/connectors" 2>/dev/null || echo "[]")
REVERSE_CONNECTORS_JSON=$(curl -s --max-time 10 "http://${CONNECT_WORKER_2_IP}:${CONNECT_WORKER_2_PORT}/connectors" 2>/dev/null || echo "[]")

# Helper to check connectors on a given Connect cluster
check_connectors() {
    local cluster_url="$1" cluster_label="$2" connectors_json="$3"

    if [[ "${connectors_json}" == "[]" || "${connectors_json}" == "" ]]; then
        warn "No connectors deployed on ${cluster_label}"
        return
    fi

    info "${cluster_label} connectors: ${connectors_json}"

    for CONN_NAME in $(echo "${connectors_json}" | jq -r '.[]' 2>/dev/null); do
        STATUS_JSON=$(curl -s --max-time 10 \
            "${cluster_url}/connectors/${CONN_NAME}/status" 2>/dev/null || echo "{}")

        CONN_STATE=$(echo "${STATUS_JSON}" | jq -r '.connector.state // "UNKNOWN"' 2>/dev/null)
        TASK_STATES=$(echo "${STATUS_JSON}" | jq -r '.tasks[]?.state // "UNKNOWN"' 2>/dev/null)

        if [[ "${CONN_STATE}" == "RUNNING" ]]; then
            ALL_TASKS_RUNNING=true
            while IFS= read -r ts; do
                if [[ "${ts}" != "RUNNING" && -n "${ts}" ]]; then
                    ALL_TASKS_RUNNING=false
                fi
            done <<< "${TASK_STATES}"

            if ${ALL_TASKS_RUNNING}; then
                pass "Connector '${CONN_NAME}' is RUNNING (all tasks RUNNING)"
            else
                warn "Connector '${CONN_NAME}' is RUNNING but some tasks are not: ${TASK_STATES}"
            fi
        elif [[ "${CONN_STATE}" == "PAUSED" ]]; then
            warn "Connector '${CONN_NAME}' is PAUSED"
        else
            fail "Connector '${CONN_NAME}' state: ${CONN_STATE}"
            TRACE=$(echo "${STATUS_JSON}" | jq -r '.tasks[0]?.trace // empty' 2>/dev/null)
            if [[ -n "${TRACE}" ]]; then
                echo -e "    ${RED}Trace: $(echo "${TRACE}" | head -3)${NC}"
            fi
        fi
    done
}

check_connectors "http://${CONNECT_WORKER_1_IP}:${CONNECT_WORKER_1_PORT}" "Forward cluster" "${CONNECTORS_JSON}"
check_connectors "http://${CONNECT_WORKER_2_IP}:${CONNECT_WORKER_2_PORT}" "Reverse cluster" "${REVERSE_CONNECTORS_JSON}"

# ---------------------------------------------------------------------------
# 4. Schema Registry
# ---------------------------------------------------------------------------
section "Schema Registry"

check_http "http://${CONNECT_1_IP}:${SCHEMA_REGISTRY_PORT}/subjects" "Schema Registry subjects endpoint"

SUBJECTS=$(curl -s --max-time 10 "http://${CONNECT_1_IP}:${SCHEMA_REGISTRY_PORT}/subjects" 2>/dev/null || echo "[]")
SUBJECT_COUNT=$(echo "${SUBJECTS}" | jq 'length' 2>/dev/null || echo "0")
info "Registered subjects: ${SUBJECT_COUNT}"

# ---------------------------------------------------------------------------
# 5. Dead Letter Queue Check
# ---------------------------------------------------------------------------
section "Dead Letter Queue (DLQ) Check"

DLQ_TOPICS=("dlq-jdbc-sink-aurora" "dlq-jdbc-sink-sqlserver")
BROKER_CONTAINER=$(docker ps -q -f name=broker --no-trunc 2>/dev/null | head -1)

for DLQ_TOPIC in "${DLQ_TOPICS[@]}"; do
    DLQ_COUNT=""
    if [[ -n "${BROKER_CONTAINER}" ]]; then
        # Check if topic exists and get message count
        DLQ_COUNT=$(docker exec -t "${BROKER_CONTAINER}" \
            kafka-run-class kafka.tools.GetOffsetShell \
            --broker-list "${BOOTSTRAP}" \
            --topic "${DLQ_TOPIC}" --time -1 2>/dev/null \
            | awk -F: '{sum += $3} END {print sum}' || echo "")
    elif command -v kafka-run-class &>/dev/null; then
        DLQ_COUNT=$(kafka-run-class kafka.tools.GetOffsetShell \
            --broker-list "${BOOTSTRAP}" \
            --topic "${DLQ_TOPIC}" --time -1 2>/dev/null \
            | awk -F: '{sum += $3} END {print sum}' || echo "")
    fi

    if [[ -z "${DLQ_COUNT}" ]]; then
        info "DLQ topic '${DLQ_TOPIC}' does not exist yet (expected — DLQ topics are created on-demand when errors occur)"
    elif [[ "${DLQ_COUNT}" -eq 0 ]]; then
        pass "DLQ topic '${DLQ_TOPIC}' is empty (0 error records)"
    else
        fail "DLQ topic '${DLQ_TOPIC}' has ${DLQ_COUNT} error record(s) — investigate!"
        info "Inspect with: kcat -C -t ${DLQ_TOPIC} -o beginning -e"
    fi
done

# ---------------------------------------------------------------------------
# 6. Consumer Lag Check
# ---------------------------------------------------------------------------
section "Consumer Lag"

CONSUMER_GROUPS=""
if [[ -n "${BROKER_CONTAINER}" ]]; then
    CONSUMER_GROUPS=$(docker exec -t "${BROKER_CONTAINER}" \
        kafka-consumer-groups --bootstrap-server "${BOOTSTRAP}" --list 2>/dev/null || echo "")
elif command -v kafka-consumer-groups &>/dev/null; then
    CONSUMER_GROUPS=$(kafka-consumer-groups --bootstrap-server "${BOOTSTRAP}" --list 2>/dev/null || echo "")
fi

if [[ -z "${CONSUMER_GROUPS}" ]]; then
    info "Consumer lag check requires kafka-consumer-groups CLI or a local broker container (not available from jumpbox)"
    info "To check lag manually: kafka-consumer-groups --bootstrap-server ${BROKER_1_IP}:9092 --list"
else
    # Check lag for Connect consumer groups (connect-*)
    while IFS= read -r GROUP; do
        [[ -z "${GROUP}" ]] && continue
        # Only check connector-related groups
        if [[ "${GROUP}" =~ ^connect- ]]; then
            LAG_OUTPUT=""
            if [[ -n "${BROKER_CONTAINER}" ]]; then
                LAG_OUTPUT=$(docker exec -t "${BROKER_CONTAINER}" \
                    kafka-consumer-groups --bootstrap-server "${BOOTSTRAP}" \
                    --describe --group "${GROUP}" 2>/dev/null || echo "")
            elif command -v kafka-consumer-groups &>/dev/null; then
                LAG_OUTPUT=$(kafka-consumer-groups --bootstrap-server "${BOOTSTRAP}" \
                    --describe --group "${GROUP}" 2>/dev/null || echo "")
            fi

            TOTAL_LAG=$(echo "${LAG_OUTPUT}" | awk 'NR>1 && $6 ~ /^[0-9]+$/ {sum+=$6} END {print sum+0}')

            if [[ "${TOTAL_LAG}" -eq 0 ]]; then
                pass "Consumer group '${GROUP}' lag: 0 (fully caught up)"
            elif [[ "${TOTAL_LAG}" -lt 1000 ]]; then
                warn "Consumer group '${GROUP}' lag: ${TOTAL_LAG} (minor lag)"
            else
                fail "Consumer group '${GROUP}' lag: ${TOTAL_LAG} (significant lag)"
            fi
        fi
    done <<< "${CONSUMER_GROUPS}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Validation Summary"
echo ""
echo -e "  Total failures:  ${RED}${FAILURES}${NC}"
echo -e "  Total warnings:  ${YELLOW}${WARNINGS}${NC}"
echo ""

if [[ ${FAILURES} -eq 0 && ${WARNINGS} -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}ALL CHECKS PASSED${NC}"
elif [[ ${FAILURES} -eq 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}PASSED WITH WARNINGS${NC}"
else
    echo -e "  ${RED}${BOLD}VALIDATION FAILED${NC}"
fi

echo ""
exit ${FAILURES}
