#!/bin/bash
# ============================================================
# Phase 2b: Distribute .env to all EC2 nodes via AWS SSM
# ============================================================
# Copies the .env configuration file to all 5 EC2 nodes.
# Run AFTER 2a-deploy-repo.sh — repo directory must already
# exist on each node so .env lands in the right place.
#
# Usage:
#   ./scripts/2b-distribute-env.sh
#
# Prerequisites:
#   1. Phase 2a completed (repo cloned to all nodes)
#   2. .env file populated with all required variables (run Phase 1 first)
#   3. AWS CLI configured with credentials
#   4. EC2 instances have SSM agent + IAM role (created by Terraform)
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
AWS_REGION=${AWS_REGION:-us-east-1}

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

error()   { echo -e "${RED}❌ ERROR:${NC} $*"; }
success() { echo -e "${GREEN}✅${NC} $*"; }
info()    { echo -e "${BLUE}ℹ️${NC}  $*"; }
warn()    { echo -e "${YELLOW}⚠️${NC}  $*"; }

# Check .env exists
if [[ ! -f "$ENV_FILE" ]]; then
    error ".env file not found at $ENV_FILE"
    echo "Run: cp .env.template .env, then fill in values and run 1-validate-env.sh"
    exit 1
fi

# Source .env to get node IPs
source "$ENV_FILE"

# Verify required variables
for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID; do
    if [[ -z "${!var}" ]]; then
        error "$var not set in .env (required for SSM)"
        exit 1
    fi
done

echo "[*] Phase 2b: Distribute .env to all 5 EC2 nodes"
echo ""

# Helper: Distribute .env to a single node via SSM
distribute_to_node() {
    local node_name="$1"
    local instance_id="$2"

    info "Distributing .env to $node_name ($instance_id)..."

    # Copy .env via SSM send-command
    # Using base64 encoding to safely pass the file content
    local env_b64
    env_b64=$(base64 -w 0 < "$ENV_FILE")

    # SSM command: decode base64 and write to .env
    # Use double-quoted JSON to allow variable expansion
    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"mkdir -p /home/ec2-user/cdc-on-ec2-docker\",\"echo '$env_b64' | base64 -d > /home/ec2-user/cdc-on-ec2-docker/.env\",\"chmod 600 /home/ec2-user/cdc-on-ec2-docker/.env\",\"chown ec2-user:ec2-user /home/ec2-user/cdc-on-ec2-docker/.env\",\"ls -lh /home/ec2-user/cdc-on-ec2-docker/.env\"]" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null)

    if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
        error "Failed to send SSM command to $node_name"
        return 1
    fi

    # Poll for completion (up to 2 minutes)
    local timeout=120
    local elapsed=0
    local status="InProgress"

    while [[ ("$status" == "InProgress" || "$status" == "Pending") && $elapsed -lt $timeout ]]; do
        sleep 3
        elapsed=$((elapsed + 3))

        status=$(aws ssm get-command-invocation \
            --region "$AWS_REGION" \
            --command-id "$cmd_id" \
            --instance-id "$instance_id" \
            --query 'Status' \
            --output text 2>/dev/null)
    done

    if [[ "$status" == "Success" ]]; then
        success "$node_name: .env distributed"
        return 0
    elif [[ "$status" == "Failed" ]]; then
        error "$node_name: .env distribution FAILED"
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
        warn "$node_name: deployment status $status (timeout)"
        return 1
    fi
}

# Distribute to all 5 nodes
echo "📦 Distributing .env to all 5 EC2 nodes..."
echo ""

failed_nodes=()

distribute_to_node "broker1" "$BROKER_1_INSTANCE_ID" || failed_nodes+=("broker1")
distribute_to_node "broker2" "$BROKER_2_INSTANCE_ID" || failed_nodes+=("broker2")
distribute_to_node "broker3" "$BROKER_3_INSTANCE_ID" || failed_nodes+=("broker3")
distribute_to_node "connect1" "$CONNECT_1_INSTANCE_ID" || failed_nodes+=("connect1")
distribute_to_node "monitor1" "$MONITOR_1_INSTANCE_ID" || failed_nodes+=("monitor1")

echo ""
if [[ ${#failed_nodes[@]} -eq 0 ]]; then
    success "All nodes have .env distributed"
    echo ""
    echo "✅ Phase 2b complete. Ready for Phase 3 (setup-ec2.sh)."
    exit 0
else
    error "Failed to distribute .env to: ${failed_nodes[*]}"
    echo "Troubleshoot with: aws ssm start-session --target <instance-id>"
    exit 1
fi
