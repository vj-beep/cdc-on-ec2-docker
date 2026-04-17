#!/bin/bash
# ============================================================
# Start services on a specific node using correct compose flags
# ============================================================
# Dispatches via SSM from jumpbox to the correct EC2 node.
# Can also run directly on-node with --local flag.
#
# Usage (from jumpbox — dispatches via SSM):
#   ./scripts/5-start-node.sh <broker1|broker2|broker3|connect|monitor>
#
# Usage (on-node — direct execution):
#   ./scripts/5-start-node.sh --local <broker1|broker2|broker3|connect|monitor>
#
# Examples:
#   ./scripts/5-start-node.sh broker1      # Dispatch to Node 1 via SSM
#   ./scripts/5-start-node.sh connect      # Dispatch to Node 4 via SSM
#   ./scripts/5-start-node.sh monitor      # Dispatch to Node 5 via SSM
# ============================================================

set -e

# Parse --local flag
LOCAL_MODE=0
if [[ "${1:-}" == "--local" ]]; then
    LOCAL_MODE=1
    shift
fi

if [[ $# -ne 1 ]]; then
    echo "Usage: $0 [--local] <broker1|broker2|broker3|connect|monitor>"
    echo ""
    echo "Examples:"
    echo "  $0 broker1      # Start broker on Node 1 (via SSM)"
    echo "  $0 broker2      # Start broker on Node 2 (via SSM)"
    echo "  $0 broker3      # Start broker on Node 3 (via SSM)"
    echo "  $0 connect      # Start Connect + Schema Registry on Node 4 (via SSM)"
    echo "  $0 monitor      # Start monitoring stack on Node 5 (via SSM)"
    echo "  $0 --local broker1   # Run directly on-node"
    exit 1
fi

NODE=$1
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# SSM Dispatch Mode (jumpbox → target node)
# Skip dispatch if CDC_ON_NODE=1 (already running on target via SSM)
# ---------------------------------------------------------------------------
if [[ "$LOCAL_MODE" -eq 0 && "${CDC_ON_NODE:-}" != "1" ]]; then
    ENV_FILE="$REPO_DIR/.env"
    AWS_REGION=${AWS_REGION:-us-east-1}

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "❌ ERROR: .env file not found at $ENV_FILE"
        exit 1
    fi
    source "$ENV_FILE"

    # Map node name to instance ID
    case $NODE in
      broker1) INSTANCE_ID="$BROKER_1_INSTANCE_ID" ;;
      broker2) INSTANCE_ID="$BROKER_2_INSTANCE_ID" ;;
      broker3) INSTANCE_ID="$BROKER_3_INSTANCE_ID" ;;
      connect) INSTANCE_ID="$CONNECT_1_INSTANCE_ID" ;;
      monitor) INSTANCE_ID="$MONITOR_1_INSTANCE_ID" ;;
      *)
        echo "❌ Unknown node: $NODE"
        exit 1
        ;;
    esac

    DEPLOY_DIR="/home/ec2-user/cdc-on-ec2-docker"
    echo "🚀 Starting $NODE on $INSTANCE_ID via SSM..."

    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "{\"commands\":[\"cd ${DEPLOY_DIR} && CDC_ON_NODE=1 bash scripts/5-start-node.sh ${NODE}\"],\"executionTimeout\":[\"600\"]}" \
        --timeout-seconds 600 \
        --output text \
        --query 'Command.CommandId' 2>/dev/null)

    if [[ -z "$cmd_id" ]]; then
        echo "❌ Failed to dispatch SSM command"
        exit 1
    fi

    echo "   ⏱️  Command ID: $cmd_id (polling for completion...)"

    # Poll for completion
    for i in $(seq 1 60); do
        status=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$INSTANCE_ID" \
            --query 'Status' --output text 2>/dev/null || echo "Pending")
        if [[ "$status" == "Success" ]]; then
            # Show output
            aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardOutputContent' --output text 2>/dev/null
            echo ""
            echo "✅ $NODE started successfully"
            exit 0
        elif [[ "$status" == "Failed" || "$status" == "TimedOut" || "$status" == "Cancelled" ]]; then
            echo "❌ $NODE failed ($status)"
            aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardErrorContent' --output text 2>/dev/null | tail -10
            exit 1
        fi
        sleep 10
    done
    echo "❌ Timed out waiting for $NODE to start"
    exit 1
fi

# ---------------------------------------------------------------------------
# On-Node Execution (--local mode)
# ---------------------------------------------------------------------------
cd "$REPO_DIR" || exit 1

# Export proxy env vars for curl/docker downloads
if [[ -f "$REPO_DIR/.env" ]]; then
    _P=$(grep "^HTTP_PROXY=" "$REPO_DIR/.env" | cut -d= -f2- || true)
    if [[ -n "$_P" ]]; then
        export HTTP_PROXY="$_P" http_proxy="$_P"
        export HTTPS_PROXY="$(grep "^HTTPS_PROXY=" "$REPO_DIR/.env" | cut -d= -f2- || true)"
        export https_proxy="${HTTPS_PROXY}"
        export NO_PROXY="$(grep "^NO_PROXY=" "$REPO_DIR/.env" | cut -d= -f2- || true)"
        export no_proxy="${NO_PROXY}"
    fi
fi

case $NODE in
  broker1)
    echo "🚀 Starting Broker 1 (Node 1)..."
    bash monitoring/jmx-exporter/download-jmx-agent.sh
    docker compose -f docker-compose.yml -f docker-compose.broker1.yml \
      up -d broker node-exporter cadvisor
    echo "✅ Broker-1 started"
    echo ""
    echo "⏳ Wait 3-5 minutes for KRaft leader election"
    echo "   Check status: docker logs \$(docker ps --filter 'name=broker-1' -q) | grep -i leader"
    ;;

  broker2)
    echo "🚀 Starting Broker 2 (Node 2)..."
    bash monitoring/jmx-exporter/download-jmx-agent.sh
    docker compose -f docker-compose.yml -f docker-compose.broker2.yml \
      up -d broker node-exporter cadvisor
    echo "✅ Broker-2 started"
    echo ""
    echo "⏳ Wait 3-5 minutes for KRaft leader election"
    echo "   Check status: docker logs \$(docker ps --filter 'name=broker-2' -q) | grep -i leader"
    ;;

  broker3)
    echo "🚀 Starting Broker 3 (Node 3)..."
    bash monitoring/jmx-exporter/download-jmx-agent.sh
    docker compose -f docker-compose.yml -f docker-compose.broker3.yml \
      up -d broker node-exporter cadvisor
    echo "✅ Broker-3 started"
    echo ""
    echo "⏳ Wait 3-5 minutes for KRaft leader election"
    echo "   Check status: docker logs \$(docker ps --filter 'name=broker-3' -q) | grep -i leader"
    ;;

  connect)
    echo "🚀 Starting Connect + Schema Registry (Node 4)..."
    echo ""
    echo "📋 Checking prerequisites:"
    if ! docker images | grep -q "cdc-connect"; then
        echo "❌ ERROR: Connect image not found"
        echo "   Build it first: docker compose -f docker-compose.connect-build.yml build"
        exit 1
    fi
    echo "✅ Connect image found"
    bash monitoring/jmx-exporter/download-jmx-agent.sh

    docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml \
      up -d connect-1 connect-2 schema-registry node-exporter cadvisor
    echo "✅ Connect + Schema Registry started"
    echo ""
    echo "⏳ Wait 1-2 minutes for services to initialize"
    echo "   Check status: curl http://localhost:8083/connectors"
    ;;

  monitor)
    echo "🚀 Starting Monitoring Stack (Node 5)..."

    # Resolve ${VAR} placeholders in prometheus.yml from .env
    PROM_TEMPLATE="$REPO_DIR/monitoring/prometheus/prometheus.yml.template"
    PROM_OUTPUT="$REPO_DIR/monitoring/prometheus/prometheus.yml"
    if [[ -f "$REPO_DIR/.env" && -f "$PROM_TEMPLATE" ]]; then
        if ! command -v envsubst &>/dev/null; then
            echo "❌ ERROR: envsubst not found. Install with: dnf install -y gettext"
            exit 1
        fi
        echo "📊 Generating prometheus.yml from template + .env..."
        set -a; source "$REPO_DIR/.env"; set +a
        envsubst < "$PROM_TEMPLATE" > "$PROM_OUTPUT"
        echo "✅ prometheus.yml resolved with actual IPs"
    else
        echo "⚠️  .env or prometheus.yml.template not found — Prometheus may not scrape correctly"
    fi

    docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml \
      up -d control-center ksqldb-server rest-proxy flink-jobmanager flink-taskmanager \
      prometheus grafana alertmanager node-exporter cadvisor
    echo "✅ Monitoring stack started"
    echo ""
    echo "Access points:"
    echo "  • Grafana: http://localhost:8080"
    echo "  • Prometheus: http://localhost:9090"
    echo "  • Control Center: http://localhost:9021"
    echo "  • ksqlDB: http://localhost:8088"
    ;;

  *)
    echo "❌ Unknown node: $NODE"
    echo "Usage: $0 <broker1|broker2|broker3|connect|monitor>"
    exit 1
    ;;
esac
