#!/bin/bash
# ============================================================
# Phase 2a: Deploy public repo to all EC2 nodes
# ============================================================
# Clones the public repo to all 5 EC2 nodes.
#
# Run BEFORE 2b-distribute-env.sh — repo directory must exist
# before .env can be copied into it.
#
# Usage (SSM mode — dispatches to all nodes from control machine):
#   ./scripts/2a-deploy-repo.sh
#
# Usage (SSH mode — run on each node after SSH-ing in):
#   ./scripts/2a-deploy-repo.sh --local
#
# Prerequisites:
#   1. .env file populated with:
#      - BROKER_1_IP, BROKER_2_IP, BROKER_3_IP
#      - CONNECT_1_IP, MONITOR_1_IP
#      - PUBLIC_REPO_URL
#      - DISPATCH_MODE (ssm or ssh)
#   2. SSM mode: AWS CLI configured, EC2 instances have SSM agent + IAM role
#   3. SSH mode: SSH into each node and run with --local
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

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"

# ---------------------------------------------------------------------------
# --local mode: clone repo on this node only (SSH mode — run per node)
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--local" ]]; then
    deploy_user="${DEPLOY_USER:-ec2-user}"
    deploy_dir="${DEPLOY_DIR:-/home/${deploy_user}/cdc-on-ec2-docker}"
    deploy_home="$(dirname "$deploy_dir")"
    repo_url="${PUBLIC_REPO_URL:-}"

    if [[ -z "$repo_url" ]]; then
        echo "❌ ERROR: PUBLIC_REPO_URL not set in .env"
        exit 1
    fi

    echo "[*] Phase 2a (local): Cloning repo on $(hostname)..."

    # Export proxy for git and dnf
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        export HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy="${HTTP_PROXY}" https_proxy="${HTTPS_PROXY}" no_proxy="${NO_PROXY}"
    fi

    which git >/dev/null 2>&1 || dnf install -y git
    mkdir -p "$deploy_home"
    rm -rf "$deploy_dir" 2>/dev/null || true
    git clone "$repo_url" "$deploy_dir"
    chown -R "${deploy_user}:${deploy_user}" "$deploy_dir"
    ls -lh "$deploy_dir/docker-compose.yml"
    echo "✅ Repo cloned to $deploy_dir"
    echo ""
    echo "Next: copy .env into $deploy_dir/.env (run 2b-distribute-env.sh from control machine, or scp manually)"
    exit 0
fi

# ---------------------------------------------------------------------------
# Remote dispatch: deploy repo to all 5 nodes (SSH or SSM)
# ---------------------------------------------------------------------------
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER}/cdc-on-ec2-docker}"

NODE_NAMES=(broker1 broker2 broker3 connect monitor)

if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    SSH_KEY="${SSH_KEY_PATH:-}"
    if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
        echo "❌ SSH_KEY_PATH not set or key not found (required for DISPATCH_MODE=ssh)"
        exit 1
    fi
    NODE_ADDRS=("$BROKER_1_IP" "$BROKER_2_IP" "$BROKER_3_IP" "$CONNECT_1_IP" "$MONITOR_1_IP")
else
    for var in BROKER_1_INSTANCE_ID BROKER_2_INSTANCE_ID BROKER_3_INSTANCE_ID CONNECT_1_INSTANCE_ID MONITOR_1_INSTANCE_ID PUBLIC_REPO_URL; do
        if [[ -z "${!var}" ]]; then
            echo "❌ ERROR: $var is not set in .env"
            exit 1
        fi
    done
    NODE_ADDRS=("$BROKER_1_INSTANCE_ID" "$BROKER_2_INSTANCE_ID" "$BROKER_3_INSTANCE_ID" "$CONNECT_1_INSTANCE_ID" "$MONITOR_1_INSTANCE_ID")
fi

echo "[*] Phase 2a: Deploy public repo to all 5 EC2 nodes (${DISPATCH_MODE^^} mode)"
echo "   Repo URL: $PUBLIC_REPO_URL"
echo ""

deploy_to_node() {
    local node_name="$1"
    local node_addr="$2"
    local repo_url="$3"

    echo "🚀 Deploying to $node_name ($node_addr)..."

    if [[ "$DISPATCH_MODE" == "ssh" ]]; then
        # SSH: clone directly — repo doesn't exist on node yet, can't use --local
        local output
        output=$(ssh -i "$SSH_KEY" \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${DEPLOY_USER}@${node_addr}" "bash -s" <<REMOTE_EOF 2>&1
set -e
export HTTP_PROXY='${HTTP_PROXY:-}' HTTPS_PROXY='${HTTPS_PROXY:-}' NO_PROXY='${NO_PROXY:-}'
export http_proxy='${HTTP_PROXY:-}' https_proxy='${HTTPS_PROXY:-}' no_proxy='${NO_PROXY:-}'
which git >/dev/null 2>&1 || sudo dnf install -y git
rm -rf ${DEPLOY_DIR} 2>/dev/null || true
git clone ${repo_url} ${DEPLOY_DIR}
ls -lh ${DEPLOY_DIR}/docker-compose.yml
REMOTE_EOF
) && {
            echo "   ✅ $node_name deployment completed successfully"
            return 0
        } || {
            echo "   ❌ $node_name deployment FAILED"
            echo "$output" | tail -5 | sed 's/^/   /'
            return 1
        }
    else
        # SSM dispatch
        local proxy_cmd="true"
        if [[ -n "${HTTP_PROXY:-}" ]]; then
            proxy_cmd="export HTTP_PROXY='${HTTP_PROXY}' HTTPS_PROXY='${HTTPS_PROXY}' NO_PROXY='${NO_PROXY}' http_proxy='${HTTP_PROXY}' https_proxy='${HTTPS_PROXY}' no_proxy='${NO_PROXY}'"
        fi
        local cmd_json
        cmd_json=$(jq -n --arg proxy "$proxy_cmd" \
            --arg deploy_home "$(dirname "$DEPLOY_DIR")" \
            --arg dirname "$(basename "$DEPLOY_DIR")" \
            --arg repo "$repo_url" \
            --arg user "$DEPLOY_USER" \
            --arg dir "$DEPLOY_DIR" \
            '{commands: [
                $proxy,
                "which git >/dev/null 2>&1 || dnf install -y git",
                ("mkdir -p " + $deploy_home),
                ("cd " + $deploy_home),
                ("rm -rf " + $dirname + " 2>/dev/null || true"),
                ("git clone " + $repo + " " + $dirname),
                ("chown -R " + $user + ":" + $user + " " + $dir),
                ("ls -lh " + $dir + "/docker-compose.yml")
            ]}'
        )

        local cmd_id
        cmd_id=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$node_addr" \
            --document-name "AWS-RunShellScript" \
            --parameters "$cmd_json" \
            --query 'Command.CommandId' \
            --output text 2>/dev/null)

        if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
            echo "   ❌ ERROR: Failed to send SSM command"
            return 1
        fi

        echo "   ⏱️  Command ID: $cmd_id (polling for completion...)"

        local timeout=300
        local elapsed=0
        local status="InProgress"

        while [[ "$status" == "InProgress" && $elapsed -lt $timeout ]]; do
            sleep 5
            elapsed=$((elapsed + 5))
            status=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$node_addr" \
                --query 'Status' \
                --output text 2>/dev/null)
        done

        if [[ "$status" == "Success" ]]; then
            echo "   ✅ $node_name deployment completed successfully"
            return 0
        elif [[ "$status" == "Failed" ]]; then
            echo "   ❌ $node_name deployment FAILED"
            local error_output
            error_output=$(aws ssm get-command-invocation \
                --region "$AWS_REGION" \
                --command-id "$cmd_id" \
                --instance-id "$node_addr" \
                --query 'StandardErrorContent' \
                --output text 2>/dev/null)
            [[ -n "$error_output" ]] && echo "   Error: $error_output"
            return 1
        else
            echo "   ⚠️  $node_name deployment status: $status (timeout after ${timeout}s)"
            return 1
        fi
    fi
}

failed=0
for i in "${!NODE_NAMES[@]}"; do
    if ! deploy_to_node "${NODE_NAMES[$i]}" "${NODE_ADDRS[$i]}" "$PUBLIC_REPO_URL"; then
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
echo "Next: ./scripts/2b-distribute-env.sh"
