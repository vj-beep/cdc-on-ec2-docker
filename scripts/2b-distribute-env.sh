#!/bin/bash
# ============================================================
# Phase 2b: Distribute .env to all EC2 nodes
# ============================================================
# Copies the .env configuration file to all 5 EC2 nodes.
# Run AFTER 2a-deploy-repo.sh — repo directory must already
# exist on each node so .env lands in the right place.
#
# Usage (SSM mode — default):
#   ./scripts/2b-distribute-env.sh
#
# Usage (SSH mode — set DISPATCH_MODE=ssh in .env):
#   ./scripts/2b-distribute-env.sh
#   (uses scp with SSH_KEY_PATH to copy .env to each node)
#
# Prerequisites:
#   1. Phase 2a completed (repo cloned to all nodes)
#   2. .env file populated with all required variables (run Phase 1 first)
#   3. SSM mode: AWS CLI configured, EC2 instances have SSM agent + IAM role
#   4. SSH mode: SSH_KEY_PATH set in .env, key authorised on all nodes
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
AWS_REGION=${AWS_REGION:-us-east-1}
DISPATCH_MODE="${DISPATCH_MODE:-ssm}"

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

# Source .env to get node IPs and dispatch config
source "$ENV_FILE"
DISPATCH_MODE="${DISPATCH_MODE:-ssm}"

# Build node map: name -> IP or instance ID depending on mode
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER}/cdc-on-ec2-docker}"

echo "[*] Phase 2b: Distribute .env to all 5 EC2 nodes (DISPATCH_MODE=$DISPATCH_MODE)"
echo ""

# ---------------------------------------------------------------------------
# SSH dispatch: scp .env to each node
# ---------------------------------------------------------------------------
distribute_ssh() {
    local node_name="$1"
    local node_ip="$2"
    local ssh_key="$3"

    info "Distributing .env to $node_name ($node_ip) via scp..."

    if scp -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
           "$ENV_FILE" "${DEPLOY_USER}@${node_ip}:${DEPLOY_DIR}/.env" 2>/dev/null; then
        # Set permissions via ssh
        ssh -i "$ssh_key" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${DEPLOY_USER}@${node_ip}" "chmod 600 ${DEPLOY_DIR}/.env" 2>/dev/null
        success "$node_name: .env distributed"
        return 0
    else
        error "$node_name ($node_ip): scp failed"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# SSM dispatch: base64-encode .env and write via send-command
# ---------------------------------------------------------------------------
distribute_ssm() {
    local node_name="$1"
    local instance_id="$2"

    info "Distributing .env to $node_name ($instance_id) via SSM..."

    local env_b64
    env_b64=$(base64 -w 0 < "$ENV_FILE")

    local cmd_id
    cmd_id=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --instance-ids "$instance_id" \
        --document-name "AWS-RunShellScript" \
        --parameters "commands=[\"mkdir -p ${DEPLOY_DIR}\",\"echo '$env_b64' | base64 -d > ${DEPLOY_DIR}/.env\",\"chmod 600 ${DEPLOY_DIR}/.env\",\"chown ${DEPLOY_USER}:${DEPLOY_USER} ${DEPLOY_DIR}/.env\",\"ls -lh ${DEPLOY_DIR}/.env\"]" \
        --query 'Command.CommandId' \
        --output text 2>/dev/null)

    if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
        error "Failed to send SSM command to $node_name"
        return 1
    fi

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
        warn "$node_name: status $status (timeout)"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Dispatch to all 5 nodes
# ---------------------------------------------------------------------------
echo "📦 Distributing .env to all 5 EC2 nodes..."
echo ""

failed_nodes=()

if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    SSH_KEY="${SSH_KEY_PATH:-}"
    if [[ -z "$SSH_KEY" ]]; then
        error "SSH_KEY_PATH not set in .env (required for DISPATCH_MODE=ssh)"
        exit 1
    fi
    if [[ ! -f "$SSH_KEY" ]]; then
        error "SSH key not found: $SSH_KEY"
        exit 1
    fi
    distribute_ssh "broker1"  "$BROKER_1_IP"  "$SSH_KEY" || failed_nodes+=("broker1")
    distribute_ssh "broker2"  "$BROKER_2_IP"  "$SSH_KEY" || failed_nodes+=("broker2")
    distribute_ssh "broker3"  "$BROKER_3_IP"  "$SSH_KEY" || failed_nodes+=("broker3")
    distribute_ssh "connect1" "$CONNECT_1_IP" "$SSH_KEY" || failed_nodes+=("connect1")
    distribute_ssh "monitor1" "$MONITOR_1_IP" "$SSH_KEY" || failed_nodes+=("monitor1")
else
    for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID; do
        if [[ -z "${!var}" ]]; then
            error "$var not set in .env (required for DISPATCH_MODE=ssm)"
            exit 1
        fi
    done
    distribute_ssm "broker1"  "$BROKER_1_INSTANCE_ID"  || failed_nodes+=("broker1")
    distribute_ssm "broker2"  "$BROKER_2_INSTANCE_ID"  || failed_nodes+=("broker2")
    distribute_ssm "broker3"  "$BROKER_3_INSTANCE_ID"  || failed_nodes+=("broker3")
    distribute_ssm "connect1" "$CONNECT_1_INSTANCE_ID" || failed_nodes+=("connect1")
    distribute_ssm "monitor1" "$MONITOR_1_INSTANCE_ID" || failed_nodes+=("monitor1")
fi

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
