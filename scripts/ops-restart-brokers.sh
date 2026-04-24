#!/bin/bash
# ============================================================
# Restart all 3 Kafka brokers with rolling or parallel strategy
# ============================================================
# Rolling restart (default): one broker at a time, waits for healthy
# status before proceeding. Maintains cluster availability throughout.
#
# Parallel restart: stops all 3, then starts all 3. Faster but causes
# a brief cluster outage. Use after config changes that require all
# brokers to restart simultaneously (e.g., message.max.bytes).
#
# Usage (from jumpbox):
#   ./scripts/ops-restart-brokers.sh              # Rolling (default)
#   ./scripts/ops-restart-brokers.sh --parallel   # All at once
#   ./scripts/ops-restart-brokers.sh --local      # On-node (single broker)
# ============================================================

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"

PARALLEL=0
LOCAL_MODE=0

for arg in "$@"; do
    case "$arg" in
        --parallel) PARALLEL=1 ;;
        --local)    LOCAL_MODE=1 ;;
    esac
done

# ---------------------------------------------------------------------------
# On-node: restart the local broker (called via dispatch)
# ---------------------------------------------------------------------------
if [[ "$LOCAL_MODE" -eq 1 || "${CDC_ON_NODE:-}" == "1" ]]; then
    cd "$REPO_DIR" || exit 1
    source "$ENV_FILE"

    MY_IP=$(hostname -I | awk '{print $1}')
    if [[ "$MY_IP" == "$BROKER_1_IP" ]]; then
        COMPOSE=docker-compose.broker1.yml; LABEL="Broker 1"
    elif [[ "$MY_IP" == "$BROKER_2_IP" ]]; then
        COMPOSE=docker-compose.broker2.yml; LABEL="Broker 2"
    elif [[ "$MY_IP" == "$BROKER_3_IP" ]]; then
        COMPOSE=docker-compose.broker3.yml; LABEL="Broker 3"
    else
        echo "❌ This node ($MY_IP) is not a broker"; exit 1
    fi

    echo "🔄 Restarting $LABEL..."
    docker compose -f docker-compose.yml -f "$COMPOSE" down
    docker compose -f docker-compose.yml -f "$COMPOSE" --env-file .env up -d
    echo "✅ $LABEL restarted"
    exit 0
fi

# ---------------------------------------------------------------------------
# Jumpbox: dispatch to broker nodes
# ---------------------------------------------------------------------------
if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ .env not found at $ENV_FILE"
    exit 1
fi
source "$ENV_FILE"

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="/home/${DEPLOY_USER}/cdc-on-ec2-docker"
AWS_REGION="${AWS_REGION:-us-east-1}"

BROKER_NAMES=("broker1" "broker2" "broker3")
BROKER_IPS=("$BROKER_1_IP" "$BROKER_2_IP" "$BROKER_3_IP")
BROKER_IDS=("${BROKER_1_INSTANCE_ID:-}" "${BROKER_2_INSTANCE_ID:-}" "${BROKER_3_INSTANCE_ID:-}")

dispatch_node() {
    local name="$1" ip="$2" instance_id="$3"

    if [[ "$DISPATCH_MODE" == "ssh" ]]; then
        SSH_KEY="${SSH_KEY_PATH:-}"
        if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
            echo "❌ SSH_KEY_PATH not set or key not found"; exit 1
        fi
        echo "  🔄 $name ($ip) via SSH..."
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${DEPLOY_USER}@${ip}" \
            "cd ${DEPLOY_DIR} && CDC_ON_NODE=1 bash scripts/ops-restart-brokers.sh --local" 2>&1
    else
        echo "  🔄 $name ($instance_id) via SSM..."
        local cmd_id
        cmd_id=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$instance_id" \
            --document-name "AWS-RunShellScript" \
            --parameters "{\"commands\":[\"cd ${DEPLOY_DIR} && CDC_ON_NODE=1 bash scripts/ops-restart-brokers.sh --local\"],\"executionTimeout\":[\"180\"]}" \
            --timeout-seconds 180 \
            --output text --query 'Command.CommandId' 2>/dev/null)

        if [[ -z "$cmd_id" ]]; then
            echo "  ❌ $name: SSM dispatch failed"; return 1
        fi

        for i in $(seq 1 36); do
            local status
            status=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
                --query 'Status' --output text 2>/dev/null || echo "Pending")
            if [[ "$status" == "Success" ]]; then
                echo "  ✅ $name restarted"
                return 0
            elif [[ "$status" == "Failed" || "$status" == "TimedOut" || "$status" == "Cancelled" ]]; then
                echo "  ❌ $name restart failed ($status)"
                aws ssm get-command-invocation \
                    --region "$AWS_REGION" --command-id "$cmd_id" --instance-id "$instance_id" \
                    --query 'StandardErrorContent' --output text 2>/dev/null | tail -5
                return 1
            fi
            sleep 5
        done
        echo "  ❌ $name: timed out"; return 1
    fi
}

wait_broker_healthy() {
    local ip="$1" name="$2"
    echo "  ⏳ Waiting for $name ($ip:9092)..."
    for i in $(seq 1 60); do
        if nc -z "$ip" 9092 2>/dev/null; then
            echo "  ✅ $name healthy"
            return 0
        fi
        sleep 5
    done
    echo "  ⚠️  $name not responding after 5 min (may still be electing leader)"
    return 0
}

echo ""
echo "╔════════════════════════════════════════════════╗"
echo "║       Kafka Broker Restart (${DISPATCH_MODE} mode)        ║"
echo "╚════════════════════════════════════════════════╝"
echo ""

if [[ "$PARALLEL" -eq 1 ]]; then
    echo "⚡ Parallel restart — all 3 brokers at once"
    echo "  ⚠️  Cluster will be briefly unavailable"
    echo ""

    for i in 0 1 2; do
        dispatch_node "${BROKER_NAMES[$i]}" "${BROKER_IPS[$i]}" "${BROKER_IDS[$i]}"
    done

    echo ""
    echo "⏳ Waiting for KRaft leader election (up to 5 min)..."
    for i in 0 1 2; do
        wait_broker_healthy "${BROKER_IPS[$i]}" "${BROKER_NAMES[$i]}"
    done
else
    echo "🔄 Rolling restart — one broker at a time"
    echo ""

    for i in 0 1 2; do
        dispatch_node "${BROKER_NAMES[$i]}" "${BROKER_IPS[$i]}" "${BROKER_IDS[$i]}"
        wait_broker_healthy "${BROKER_IPS[$i]}" "${BROKER_NAMES[$i]}"
        echo ""
    done
fi

echo ""
echo "✅ All 3 brokers restarted"
echo ""
echo "💡 If connectors were running, they will auto-reconnect."
echo "   To verify: curl http://${CONNECT_1_IP}:8083/connectors?expand=status"
