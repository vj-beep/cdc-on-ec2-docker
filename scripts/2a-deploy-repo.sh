#!/bin/bash
# ============================================================
# Phase 2a: Deploy public repo to all EC2 nodes via AWS SSM
# ============================================================
# Clones the public repo to all 5 EC2 nodes via SSM.
# Works for private EC2 instances without SSH key distribution.
#
# Run BEFORE 2b-distribute-env.sh — repo directory must exist
# before .env can be copied into it.
#
# Usage:
#   ./scripts/2a-deploy-repo.sh
#
# Prerequisites:
#   1. .env file populated with:
#      - BROKER_1_IP, BROKER_2_IP, BROKER_3_IP
#      - CONNECT_1_IP, MONITOR_1_IP
#      - PUBLIC_REPO_URL
#   2. AWS CLI configured with credentials
#   3. EC2 instances have SSM agent + IAM role (created by Terraform)
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
AWS_REGION=${AWS_REGION:-us-east-1}

# Verify .env exists
if [[ ! -f "$ENV_FILE" ]]; then
    echo "❌ ERROR: .env file not found at $ENV_FILE"
    echo "Run: cp .env.template .env, then fill in values"
    exit 1
fi

# Source .env to get node IPs and repo URL
source "$ENV_FILE"

# Verify required variables
for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID PUBLIC_REPO_URL; do
    if [[ -z "${!var}" ]]; then
        echo "❌ ERROR: $var is not set in .env"
        exit 1
    fi
done

# Helper: Deploy to single node via SSM
deploy_to_node() {
    local node_name="$1"
    local instance_id="$2"
    local repo_url="$3"

    echo "🚀 Deploying to $node_name ($instance_id)..."

    # Create temporary JSON for SSM command
    local deploy_user="${DEPLOY_USER:-ec2-user}"
    local deploy_dir="${DEPLOY_DIR:-/home/${deploy_user}/cdc-on-ec2-docker}"
    local deploy_home=$(dirname "$deploy_dir")
    local cmd_json
    cmd_json=$(cat <<CMDJSON
{
  "commands": [
    "mkdir -p $deploy_home",
    "cd $deploy_home",
    "rm -rf $(basename $deploy_dir) 2>/dev/null || true",
    "git clone $repo_url $(basename $deploy_dir)",
    "chown -R ${deploy_user}:${deploy_user} $deploy_dir",
    "ls -lh $deploy_dir/docker-compose.yml"
  ]
}
CMDJSON
)

    # Deploy via SSM Session Manager
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "$cmd_json" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null)

    if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
        echo "   ❌ ERROR: Failed to send SSM command"
        return 1
    fi

    echo "   ⏱️  Command ID: $cmd_id (polling for completion...)"

    # Poll for completion (up to 3 minutes)
    local timeout=180
    local elapsed=0
    local status="InProgress"

    while [[ "$status" == "InProgress" && $elapsed -lt $timeout ]]; do
        sleep 5
        elapsed=$((elapsed + 5))

        status=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text 2>/dev/null)
    done

    if [[ "$status" == "Success" ]]; then
        echo "   ✅ $node_name deployment completed successfully"
        return 0
    elif [[ "$status" == "Failed" ]]; then
        echo "   ❌ $node_name deployment FAILED"
        # Show error output for debugging
        local error_output
        error_output=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'StandardErrorContent' \
            --output text 2>/dev/null)
        [[ -n "$error_output" ]] && echo "   Error: $error_output"
        return 1
    else
        echo "   ⚠️  $node_name deployment status: $status (timeout after ${timeout}s)"
        return 1
    fi
}

echo "[*] Phase 2a: Deploy public repo to all 5 EC2 nodes via SSM"
echo "   Repo URL: $PUBLIC_REPO_URL"
echo "   Region: $AWS_REGION"
echo ""

# Deploy to each node (ordered for predictable output)
NODE_NAMES=(broker1 broker2 broker3 connect monitor)
NODE_IDS=("$BROKER_1_INSTANCE_ID" "$BROKER_2_INSTANCE_ID" "$BROKER_3_INSTANCE_ID" "$CONNECT_1_INSTANCE_ID" "$MONITOR_1_INSTANCE_ID")

failed=0
for i in "${!NODE_NAMES[@]}"; do
    if ! deploy_to_node "${NODE_NAMES[$i]}" "${NODE_IDS[$i]}" "$PUBLIC_REPO_URL"; then
        failed=$((failed + 1))
    fi
done

echo ""
if [[ $failed -eq 0 ]]; then
    echo "✅ All nodes deployed successfully"
else
    echo "⚠️  $failed node(s) failed deployment"
    exit 1
fi

echo ""
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER}/cdc-on-ec2-docker}"
echo "📋 Verify deployment on a node:"
echo "   aws ssm start-session --region $AWS_REGION --target <instance-id>"
echo "   ls $DEPLOY_DIR/docker-compose.yml"
