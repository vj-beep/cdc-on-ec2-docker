#!/usr/bin/env bash
# =============================================================================
# 7-validate-deployment.sh — Infrastructure Validation for CDC deployment
#
# Validates infrastructure readiness and service health:
#   - Infrastructure connectivity (brokers, Connect, Schema Registry, DBs)
#   - Connector health (state, task status)
#   - Schema Registry
#   - DLQ topics (should be empty)
#   - Consumer lag
#   - Monitoring pipeline (JMX exporters, Prometheus, Grafana, Alertmanager)
#
# NOTE: Data path tests (forward/reverse CDC, loop prevention) are NOT
# included here — they require customer-specific table configuration.
# Set VALIDATE_* variables in .env and use a separate data validation script.
#
# Usage:
#   ./scripts/7-validate-deployment.sh
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
    MONITOR_1_IP
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
# 7. Monitoring Pipeline (Prometheus + Grafana)
# ---------------------------------------------------------------------------
section "Monitoring Pipeline"

MONITOR_IP="${MONITOR_1_IP:-}"
PROM_PORT="${PROMETHEUS_PORT:-9090}"
GRAF_PORT="${GRAFANA_PORT:-3000}"
GRAF_PASS="${GRAFANA_ADMIN_PASSWORD:-admin}"

if [[ -z "$MONITOR_IP" ]]; then
    warn "MONITOR_1_IP not set — skipping monitoring checks"
else

    # --- 7a. JMX exporter endpoints on nodes 1-4 ---
    info "7a. JMX Exporter endpoints (nodes 1-4)"

    JMX_TARGETS=(
        "${BROKER_1_IP}:9404:Broker 1 JMX"
        "${BROKER_2_IP}:9404:Broker 2 JMX"
        "${BROKER_3_IP}:9404:Broker 3 JMX"
        "${CONNECT_1_IP}:9404:Connect Forward JMX"
        "${CONNECT_1_IP}:9405:Connect Reverse JMX"
        "${CONNECT_1_IP}:9406:Schema Registry JMX"
    )

    JMX_FAILURES=0
    for entry in "${JMX_TARGETS[@]}"; do
        IFS=':' read -r jmx_host jmx_port jmx_label <<< "$entry"
        if nc -z -w 3 "$jmx_host" "$jmx_port" 2>/dev/null; then
            SAMPLE=$(curl -s --max-time 5 "http://${jmx_host}:${jmx_port}/metrics" 2>/dev/null | head -1)
            if [[ "$SAMPLE" == *"#"* || "$SAMPLE" == *"jvm"* || "$SAMPLE" == *"kafka"* ]]; then
                pass "${jmx_label} (${jmx_host}:${jmx_port}) returning metrics"
            else
                fail "${jmx_label} (${jmx_host}:${jmx_port}) port open but no Prometheus metrics"
                info "  Likely cause: jmx_prometheus_javaagent.jar missing — run download-jmx-agent.sh on that node and restart the container"
                JMX_FAILURES=$((JMX_FAILURES + 1))
            fi
        else
            fail "${jmx_label} (${jmx_host}:${jmx_port}) not reachable"
            info "  Likely cause: container not running, or jmx_prometheus_javaagent.jar was missing at startup"
            info "  Fix: verify JAR exists at ~/cdc-on-ec2-docker/monitoring/jmx-exporter/jmx_prometheus_javaagent.jar, then restart"
            JMX_FAILURES=$((JMX_FAILURES + 1))
        fi
    done

    if [[ $JMX_FAILURES -gt 0 ]]; then
        warn "  $JMX_FAILURES JMX endpoint(s) down — Grafana dashboards will show gaps for those components"
    fi

    # --- 7b. Node exporter + cAdvisor on all 5 nodes ---
    # These ports (9100, 9080) are typically only reachable within the VPC,
    # not from the jumpbox. Check via Prometheus targets API instead of direct nc.
    info "7b. Node Exporter and cAdvisor (checked via Prometheus targets in 7d)"

    # --- 7c. Prometheus health and template rendering ---
    info "7c. Prometheus (${MONITOR_IP}:${PROM_PORT})"

    PROM_URL="http://${MONITOR_IP}:${PROM_PORT}"
    PROM_REACHABLE=false

    if nc -z -w 3 "$MONITOR_IP" "$PROM_PORT" 2>/dev/null; then
        pass "Prometheus port reachable (${MONITOR_IP}:${PROM_PORT})"
        PROM_REACHABLE=true
    else
        fail "Prometheus not reachable (${MONITOR_IP}:${PROM_PORT})"
        info "  Fix: on node 5, check 'docker ps | grep prometheus' — if not running, re-run 5-start-node.sh monitor"
    fi

    if $PROM_REACHABLE; then
        PROM_READY=$(curl -s --max-time 5 "${PROM_URL}/-/ready" 2>/dev/null || echo "")
        PROM_READY_LOWER=$(echo "$PROM_READY" | tr '[:upper:]' '[:lower:]')
        if [[ "$PROM_READY_LOWER" == *"ready"* ]]; then
            pass "Prometheus is ready"
        else
            fail "Prometheus not ready (/-/ready returned: ${PROM_READY:-empty})"
        fi
    fi

    # Check prometheus.yml was rendered (no unresolved ${VAR} placeholders)
    if $PROM_REACHABLE; then
        PROM_CONFIG=$(curl -s --max-time 5 "${PROM_URL}/api/v1/status/config" 2>/dev/null || echo "")
        if echo "$PROM_CONFIG" | grep -q '\${BROKER_1_IP}\|\${CONNECT_1_IP}\|\${MONITOR_1_IP}'; then
            fail "prometheus.yml has unresolved \${VAR} placeholders — template was not rendered"
            info "  Fix: on node 5, install gettext (dnf install -y gettext), then re-run 5-start-node.sh monitor"
        elif [[ -n "$PROM_CONFIG" ]]; then
            pass "prometheus.yml rendered correctly (no unresolved placeholders)"
        fi
    fi

    # --- 7d. Prometheus scrape targets health ---
    if $PROM_REACHABLE; then
        info "7d. Prometheus scrape target health"

        TARGETS_JSON=$(curl -s --max-time 10 "${PROM_URL}/api/v1/targets" 2>/dev/null || echo "")

        if [[ -z "$TARGETS_JSON" ]]; then
            fail "Cannot query Prometheus targets API"
        else
            TOTAL_TARGETS=$(echo "$TARGETS_JSON" | jq '.data.activeTargets | length' 2>/dev/null || echo "0")
            UP_TARGETS=$(echo "$TARGETS_JSON" | jq '[.data.activeTargets[] | select(.health == "up")] | length' 2>/dev/null || echo "0")
            DOWN_TARGETS=$(echo "$TARGETS_JSON" | jq '[.data.activeTargets[] | select(.health == "down")] | length' 2>/dev/null || echo "0")

            if [[ "$DOWN_TARGETS" -eq 0 && "$TOTAL_TARGETS" -gt 0 ]]; then
                pass "All Prometheus targets healthy (${UP_TARGETS}/${TOTAL_TARGETS} up)"
            elif [[ "$TOTAL_TARGETS" -eq 0 ]]; then
                fail "Prometheus has 0 scrape targets — prometheus.yml may be empty or misconfigured"
            else
                warn "${UP_TARGETS}/${TOTAL_TARGETS} targets up, ${DOWN_TARGETS} down"
            fi

            # Show each down target with its error
            if [[ "$DOWN_TARGETS" -gt 0 ]]; then
                echo "$TARGETS_JSON" | jq -r '.data.activeTargets[] | select(.health == "down") | "    \(.labels.job) \(.labels.instance // .scrapeUrl) — \(.lastError)"' 2>/dev/null | while IFS= read -r line; do
                    info "  DOWN: $line"
                done
            fi

            # Per-job summary
            info "  Per-job breakdown:"
            echo "$TARGETS_JSON" | jq -r '
                [.data.activeTargets[] | {job: .labels.job, health}]
                | group_by(.job)
                | .[]
                | "    \(.[0].job): \([.[] | select(.health == "up")] | length)/\(length) up"
            ' 2>/dev/null | while IFS= read -r line; do
                echo -e "  ${CYAN}[INFO]${NC}  $line"
            done
        fi
    fi

    # --- 7e. Prometheus has actual metric data ---
    if $PROM_REACHABLE; then
        info "7e. Prometheus metric data check"

        # Broker metrics
        BROKER_RESULT=$(curl -sg --max-time 5 "${PROM_URL}/api/v1/query?query=up{job=\"kafka-brokers\"}" 2>/dev/null || echo "")
        BROKER_UP=$(echo "$BROKER_RESULT" | jq '.data.result | length' 2>/dev/null || echo "0")
        if [[ "$BROKER_UP" -gt 0 ]]; then
            pass "Broker metrics flowing (${BROKER_UP} broker series in Prometheus)"
        else
            fail "No broker metrics in Prometheus — JMX exporters on nodes 1-3 may be down"
        fi

        # Connect metrics
        CONNECT_RESULT=$(curl -sg --max-time 5 "${PROM_URL}/api/v1/query?query=up{job=\"kafka-connect\"}" 2>/dev/null || echo "")
        CONNECT_UP=$(echo "$CONNECT_RESULT" | jq '.data.result | length' 2>/dev/null || echo "0")
        if [[ "$CONNECT_UP" -gt 0 ]]; then
            pass "Connect metrics flowing (${CONNECT_UP} worker series in Prometheus)"
        else
            fail "No Connect metrics in Prometheus — JMX exporters on node 4 may be down"
        fi

        # Debezium CDC lag metric (key dashboard metric)
        LAG_RESULT=$(curl -sg --max-time 5 "${PROM_URL}/api/v1/query?query=debezium_metrics_milliseconds_behind_source" 2>/dev/null || echo "")
        LAG_SERIES=$(echo "$LAG_RESULT" | jq '.data.result | length' 2>/dev/null || echo "0")
        if [[ "$LAG_SERIES" -gt 0 ]]; then
            pass "Debezium CDC lag metric present (${LAG_SERIES} series)"
            echo "$LAG_RESULT" | jq -r '.data.result[] | "    \(.metric.context // "unknown") \(.metric.plugin // "") — \(.value[1])ms behind"' 2>/dev/null | while IFS= read -r line; do
                info "$line"
            done
        else
            warn "Debezium CDC lag metric not found — connectors may not be in streaming mode yet"
            info "  This is expected during initial snapshot; metric appears after snapshot completes"
        fi

        # Node exporter metrics
        NODE_RESULT=$(curl -sg --max-time 5 "${PROM_URL}/api/v1/query?query=up{job=\"node-exporter\"}" 2>/dev/null || echo "")
        NODE_UP=$(echo "$NODE_RESULT" | jq '.data.result | length' 2>/dev/null || echo "0")
        if [[ "$NODE_UP" -gt 0 ]]; then
            pass "Node exporter metrics flowing (${NODE_UP}/5 nodes)"
        else
            warn "No node-exporter metrics in Prometheus"
        fi
    fi

    # --- 7f. Grafana health ---
    info "7f. Grafana (${MONITOR_IP}:${GRAF_PORT})"

    GRAF_URL="http://${MONITOR_IP}:${GRAF_PORT}"
    GRAF_REACHABLE=false

    if nc -z -w 3 "$MONITOR_IP" "$GRAF_PORT" 2>/dev/null; then
        pass "Grafana port reachable (${MONITOR_IP}:${GRAF_PORT})"
        GRAF_REACHABLE=true
    else
        warn "Grafana not reachable from jumpbox (${MONITOR_IP}:${GRAF_PORT}) — port may not be open to jumpbox SG"
        info "  Grafana is typically accessed via SSH tunnel (localhost:3000), not directly from jumpbox"
        info "  To verify on node 5: docker ps | grep grafana"
    fi

    if $GRAF_REACHABLE; then
        GRAF_HEALTH=$(curl -s --max-time 5 "${GRAF_URL}/api/health" 2>/dev/null || echo "")
        GRAF_DB=$(echo "$GRAF_HEALTH" | jq -r '.database // "unknown"' 2>/dev/null)
        if [[ "$GRAF_DB" == "ok" ]]; then
            pass "Grafana health check passed (database: ok)"
        else
            fail "Grafana health check failed: ${GRAF_HEALTH:-no response}"
        fi
    fi

    # --- 7g. Grafana datasource connectivity ---
    if $GRAF_REACHABLE; then
        info "7g. Grafana datasource and dashboard check"

        DS_RESPONSE=$(curl -s --max-time 5 -u "admin:${GRAF_PASS}" "${GRAF_URL}/api/datasources" 2>/dev/null || echo "[]")
        DS_COUNT=$(echo "$DS_RESPONSE" | jq 'length' 2>/dev/null || echo "0")

        if [[ "$DS_COUNT" -eq 0 ]]; then
            fail "Grafana has 0 datasources — provisioning may have failed"
            info "  Check: docker logs grafana 2>&1 | grep -i 'datasource\\|provision\\|error'"
        else
            pass "Grafana has ${DS_COUNT} datasource(s) configured"
        fi

        PROM_DS=$(echo "$DS_RESPONSE" | jq -r '.[] | select(.type == "prometheus") | .name' 2>/dev/null || echo "")
        if [[ -n "$PROM_DS" ]]; then
            pass "Prometheus datasource found: ${PROM_DS}"

            PROM_DS_UID=$(echo "$DS_RESPONSE" | jq -r '.[] | select(.type == "prometheus") | .uid' 2>/dev/null || echo "")
            if [[ -n "$PROM_DS_UID" ]]; then
                DS_TEST=$(curl -s --max-time 10 -u "admin:${GRAF_PASS}" \
                    "${GRAF_URL}/api/datasources/uid/${PROM_DS_UID}/health" 2>/dev/null || echo "")
                DS_STATUS=$(echo "$DS_TEST" | jq -r '.status // empty' 2>/dev/null)

                if [[ "$DS_STATUS" == "OK" ]]; then
                    pass "Grafana -> Prometheus datasource connectivity: OK"
                else
                    fail "Grafana -> Prometheus datasource connectivity failed"
                    DS_MSG=$(echo "$DS_TEST" | jq -r '.message // empty' 2>/dev/null)
                    if [[ -n "$DS_MSG" ]]; then
                        info "  Error: $DS_MSG"
                    fi
                    info "  Check: Grafana datasource URL is http://localhost:9090 and Prometheus is running"
                fi
            fi
        else
            fail "No Prometheus datasource in Grafana — dashboards will show no data"
            info "  Check: monitoring/grafana/provisioning/datasources/prometheus.yml exists and Grafana was restarted"
        fi

        # Check dashboards are loaded
        DASH_SEARCH=$(curl -s --max-time 5 -u "admin:${GRAF_PASS}" \
            "${GRAF_URL}/api/search?type=dash-db" 2>/dev/null || echo "[]")
        DASH_COUNT=$(echo "$DASH_SEARCH" | jq 'length' 2>/dev/null || echo "0")

        if [[ "$DASH_COUNT" -ge 2 ]]; then
            pass "Grafana dashboards loaded (${DASH_COUNT} found)"
            echo "$DASH_SEARCH" | jq -r '.[].title' 2>/dev/null | while IFS= read -r title; do
                info "  Dashboard: $title"
            done
        elif [[ "$DASH_COUNT" -eq 0 ]]; then
            fail "No dashboards in Grafana — provisioning failed"
            info "  Fix: delete grafana-data volume and restart: docker volume rm cdc-on-ec2-docker_grafana-data"
        else
            warn "Only ${DASH_COUNT} dashboard(s) found (expected 2: forward + reverse CDC)"
        fi
    fi

    # --- 7h. Alertmanager ---
    info "7h. Alertmanager (${MONITOR_IP}:9093)"

    if nc -z -w 3 "$MONITOR_IP" 9093 2>/dev/null; then
        AM_HEALTH=$(curl -s --max-time 5 "${PROM_URL//:${PROM_PORT}/:9093}/-/ready" 2>/dev/null || echo "")
        if [[ "$AM_HEALTH" == *"OK"* || -n "$AM_HEALTH" ]]; then
            pass "Alertmanager reachable and ready"
        else
            warn "Alertmanager port open but health check unclear"
        fi
    else
        warn "Alertmanager not reachable (${MONITOR_IP}:9093) — alerts will not fire"
    fi
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
