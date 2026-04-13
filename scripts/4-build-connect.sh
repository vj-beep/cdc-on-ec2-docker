#!/bin/bash
# ============================================================
# Phase 4: Build Custom Connect Image
# ============================================================
# Builds the custom Debezium + JDBC Connect image on Node 4
#
# Prerequisites:
#   - Phase 3 completed (setup-ec2.sh on all nodes)
#   - Node 4 (connect) has repo cloned and .env available
#
# Usage: ./scripts/4-build-connect.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
AWS_REGION=${AWS_REGION:-us-east-1}

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[ERROR] .env not found"
    exit 1
fi

source "$ENV_FILE"

if [[ -z "$CONNECT_1_IP" ]]; then
    echo "[ERROR] CONNECT_1_IP not set"
    exit 1
fi

get_instance_id_by_ip() {
    aws ec2 describe-instances \
        --region "$AWS_REGION" \
        --filters "Name=private-ip-address,Values=$1" "Name=instance-state-name,Values=running" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null
}

echo "[*] Phase 4: Building custom Connect image on Node 4 ($CONNECT_1_IP)..."

instance_id=$(get_instance_id_by_ip "$CONNECT_1_IP")
if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
    echo "[ERROR] Cannot find Node 4 instance"
    exit 1
fi

echo "[*] Instance ID: $instance_id"
echo "[*] Building image (this may take 5-10 minutes)..."

cmd_json=$(cat <<'EOF'
{
  "commands": [
    "cd /home/ec2-user/cdc-on-ec2-docker",
    "DOCKER_BUILDKIT=0 docker compose -f docker-compose.connect-build.yml build",
    "docker images | grep cdc-connect"
  ]
}
EOF
)

cmd_id=$(aws ssm send-command \
    --region "$AWS_REGION" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "$cmd_json" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)

if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
    echo "[ERROR] Failed to send build command"
    exit 1
fi

# Poll for completion (up to 15 minutes for Maven downloads)
timeout=900
elapsed=0
status="Pending"

while [[ ("$status" == "InProgress" || "$status" == "Pending") && $elapsed -lt $timeout ]]; do
    sleep 10
    elapsed=$((elapsed + 10))
    status=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --query 'Status' \
        --output text 2>/dev/null)
    echo -n "."
done

echo ""

if [[ "$status" == "Success" ]]; then
    echo "[OK] Connect image built successfully"
    echo ""
    echo "Next: ./scripts/5-start-node.sh connect"
else
    echo "[ERROR] Build failed. Status: $status"
    error_output=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$cmd_id" \
        --instance-id "$instance_id" \
        --query 'StandardErrorContent' \
        --output text 2>/dev/null)
    [[ -n "$error_output" ]] && echo "Error: $error_output"
    exit 1
fi
