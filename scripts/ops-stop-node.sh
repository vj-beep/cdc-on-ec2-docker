#!/bin/bash
# ============================================================
# Stop services on a specific node and clean up
# ============================================================
# Dispatches via SSM from jumpbox to the correct EC2 node.
# Can also run directly on-node with --local flag.
#
# Usage (from jumpbox — dispatches via SSM):
#   ./scripts/ops-stop-node.sh <broker1|broker2|broker3|connect|monitor>
#
# Usage (on-node — direct execution):
#   ./scripts/ops-stop-node.sh --local <broker1|broker2|broker3|connect|monitor>
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
    echo "  $0 broker1      # Stop broker on Node 1 (via SSM)"
    echo "  $0 connect      # Stop Connect + Schema Registry on Node 4 (via SSM)"
    echo "  $0 --local broker1   # Run directly on-node"
    exit 1
fi

NODE=$1
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# SSM Dispatch Mode (jumpbox → target node)
# ---------------------------------------------------------------------------
if [[ "$LOCAL_MODE" -eq 0 && "${CDC_ON_NODE:-}" != "1" ]]; then
    ENV_FILE="$REPO_DIR/.env"
    AWS_REGION=${AWS_REGION:-us-east-1}

    if [[ ! -f "$ENV_FILE" ]]; then
        echo "❌ ERROR: .env file not found at $ENV_FILE"
        exit 1
    fi
    source "$ENV_FILE"

    case $NODE in
      broker1) INSTANCE_ID="$BROKER_1_INSTANCE_ID" ;;
      broker2) INSTANCE_ID="$BROKER_2_INSTANCE_ID" ;;
      broker3) INSTANCE_ID="$BROKER_3_INSTANCE_ID" ;;
      connect) INSTANCE_ID="$CONNECT_1_INSTANCE_ID" ;;
      monitor) INSTANCE_ID="$MONITOR_1_INSTANCE_ID" ;;
      *) echo "❌ Unknown node: $NODE"; exit 1 ;;
    esac

    DEPLOY_DIR="/home/ec2-user/cdc-on-ec2-docker"
    echo "🛑 Stopping $NODE on $INSTANCE_ID via SSM..."

    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --parameters "{\"commands\":[\"cd ${DEPLOY_DIR} && CDC_ON_NODE=1 bash scripts/ops-stop-node.sh ${NODE}\"],\"executionTimeout\":[\"120\"]}" \
        --timeout-seconds 120 \
        --output text \
        --query 'Command.CommandId' 2>/dev/null)

    if [[ -z "$cmd_id" ]]; then
        echo "❌ Failed to dispatch SSM command"
        exit 1
    fi

    for i in $(seq 1 30); do
        status=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$INSTANCE_ID" \
            --query 'Status' --output text 2>/dev/null || echo "Pending")
        if [[ "$status" == "Success" ]]; then
            aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardOutputContent' --output text 2>/dev/null
            echo "✅ $NODE stopped successfully"
            exit 0
        elif [[ "$status" == "Failed" || "$status" == "TimedOut" || "$status" == "Cancelled" ]]; then
            echo "❌ $NODE stop failed ($status)"
            aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$INSTANCE_ID" \
                --query 'StandardErrorContent' --output text 2>/dev/null | tail -5
            exit 1
        fi
        sleep 5
    done
    echo "❌ Timed out waiting for $NODE to stop"
    exit 1
fi

# ---------------------------------------------------------------------------
# On-Node Execution
# ---------------------------------------------------------------------------
cd "$REPO_DIR" || exit 1

case $NODE in
  broker1)
    echo "🛑 Stopping Broker 1 (Node 1)..."
    docker compose -f docker-compose.yml -f docker-compose.broker1.yml down
    echo "✅ Broker-1 stopped"
    ;;

  broker2)
    echo "🛑 Stopping Broker 2 (Node 2)..."
    docker compose -f docker-compose.yml -f docker-compose.broker2.yml down
    echo "✅ Broker-2 stopped"
    ;;

  broker3)
    echo "🛑 Stopping Broker 3 (Node 3)..."
    docker compose -f docker-compose.yml -f docker-compose.broker3.yml down
    echo "✅ Broker-3 stopped"
    ;;

  connect)
    echo "🛑 Stopping Connect + Schema Registry (Node 4)..."
    docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml down
    echo "✅ Connect + Schema Registry stopped"
    ;;

  monitor)
    echo "🛑 Stopping Monitoring Stack (Node 5)..."
    docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml down
    echo "✅ Monitoring stack stopped"
    echo ""
    echo "Note: Volumes are preserved for data recovery"
    ;;

  *)
    echo "❌ Unknown node: $NODE"
    echo "Usage: $0 <broker1|broker2|broker3|connect|monitor>"
    exit 1
    ;;
esac

echo ""
echo "💡 Tip: Use './scripts/start-node.sh $NODE' to resume"
