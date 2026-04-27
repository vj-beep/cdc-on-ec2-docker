#!/bin/bash
# ============================================================
# ops-refresh-grafana.sh — Pull repo, render dashboards, cycle Grafana
# ============================================================
# Pulls the latest repo on Node 5, renders .json.template files
# via envsubst, deletes the Grafana SQLite volume (cached dashboards),
# and restarts the Grafana container so provisioned dashboards reload.
#
# Usage (from jumpbox — dispatches to Node 5 via SSM or SSH):
#   ./scripts/ops-refresh-grafana.sh
#
# Usage (on-node — direct execution):
#   ./scripts/ops-refresh-grafana.sh --local
# ============================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Parse --local flag
LOCAL_MODE=0
if [[ "${1:-}" == "--local" ]]; then
    LOCAL_MODE=1
    shift
fi

# ---------------------------------------------------------------------------
# Dispatch Mode (jumpbox → Node 5 via SSM or SSH)
# ---------------------------------------------------------------------------
if [[ "$LOCAL_MODE" -eq 0 && "${CDC_ON_NODE:-}" != "1" ]]; then
    ENV_FILE="$REPO_DIR/.env"
    if [[ ! -f "$ENV_FILE" ]]; then
        error ".env file not found at $ENV_FILE"
        exit 1
    fi
    source "$ENV_FILE"

    AWS_REGION="${AWS_REGION:-us-east-1}"
    DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
    DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
    DEPLOY_DIR="/home/${DEPLOY_USER}/cdc-on-ec2-docker"
    MONITOR_IP="${MONITOR_1_IP:-}"
    INSTANCE_ID="${MONITOR_1_INSTANCE_ID:-}"

    if [[ "$DISPATCH_MODE" == "ssh" ]]; then
        SSH_KEY="${SSH_KEY_PATH:-}"
        if [[ -z "$SSH_KEY" || ! -f "$SSH_KEY" ]]; then
            error "SSH_KEY_PATH not set or key not found (required for DISPATCH_MODE=ssh)"
            exit 1
        fi

        info "Refreshing Grafana on monitor ($MONITOR_IP) via SSH..."
        ssh -i "$SSH_KEY" \
            -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
            "${DEPLOY_USER}@${MONITOR_IP}" \
            "cd ${DEPLOY_DIR} && CDC_ON_NODE=1 bash scripts/ops-refresh-grafana.sh" 2>&1

        if [[ $? -eq 0 ]]; then
            info "Grafana refreshed successfully"
        else
            error "Grafana refresh failed via SSH"
            exit 1
        fi
    else
        if [[ -z "$INSTANCE_ID" ]]; then
            error "MONITOR_1_INSTANCE_ID not set in .env"
            exit 1
        fi

        info "Refreshing Grafana on monitor ($INSTANCE_ID) via SSM..."

        REMOTE_CMD="cd ${DEPLOY_DIR} && CDC_ON_NODE=1 bash scripts/ops-refresh-grafana.sh"

        PARAMS=$(jq -n --arg cmd "$REMOTE_CMD" '{"commands":[$cmd],"executionTimeout":["180"]}')

        cmd_id=$(aws ssm send-command \
            --region "$AWS_REGION" \
            --instance-ids "$INSTANCE_ID" \
            --document-name "AWS-RunShellScript" \
            --parameters "$PARAMS" \
            --timeout-seconds 180 \
            --output text \
            --query 'Command.CommandId' 2>/dev/null)

        if [[ -z "$cmd_id" ]]; then
            error "Failed to dispatch SSM command"
            exit 1
        fi

        for i in $(seq 1 36); do
            sleep 5
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
                info "Grafana refreshed successfully"
                exit 0
            elif [[ "$status" == "Failed" || "$status" == "TimedOut" || "$status" == "Cancelled" ]]; then
                error "Grafana refresh failed ($status)"
                aws ssm get-command-invocation \
                    --region "$AWS_REGION" \
                    --command-id "$cmd_id" \
                    --instance-id "$INSTANCE_ID" \
                    --query 'StandardErrorContent' --output text 2>/dev/null | tail -10
                exit 1
            fi
        done
        error "Timed out waiting for Grafana refresh"
        exit 1
    fi
    exit 0
fi

# ---------------------------------------------------------------------------
# On-Node Execution
# ---------------------------------------------------------------------------
cd "$REPO_DIR" || exit 1

ENV_FILE="$REPO_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
    error ".env not found at $ENV_FILE"
    exit 1
fi

set -a
source "$ENV_FILE"
set +a

COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.ksqldb-monitoring.yml"

# Step 1: Pull latest repo
info "Pulling latest repo..."
export http_proxy="${HTTP_PROXY:-}" https_proxy="${HTTPS_PROXY:-}" no_proxy="${NO_PROXY:-}"
export HTTP_PROXY HTTPS_PROXY NO_PROXY
git pull 2>&1 || { error "git pull failed"; exit 1; }
info "Repo updated"

# Step 2: Render dashboard templates
info "Rendering Grafana dashboard templates..."
if ! command -v envsubst &>/dev/null; then
    error "envsubst not found. Install with: dnf install -y gettext"
    exit 1
fi

DASH_DIR="$REPO_DIR/monitoring/grafana/dashboards"
export SQLSERVER_TOPIC_PREFIX AURORA_TOPIC_PREFIX
DASH_VARS='$SQLSERVER_TOPIC_PREFIX $AURORA_TOPIC_PREFIX'

if [[ -z "${SQLSERVER_TOPIC_PREFIX:-}" || -z "${AURORA_TOPIC_PREFIX:-}" ]]; then
    warn "SQLSERVER_TOPIC_PREFIX or AURORA_TOPIC_PREFIX not set — dashboard topic filters may be empty"
fi

rendered=0
for tmpl in "$DASH_DIR"/*.json.template; do
    [[ -f "$tmpl" ]] || continue
    out="${tmpl%.template}"
    envsubst "$DASH_VARS" < "$tmpl" > "$out"
    info "Generated $(basename "$out")"
    rendered=$((rendered + 1))
done

if [[ $rendered -eq 0 ]]; then
    warn "No .json.template files found in $DASH_DIR"
fi

# Step 3: Stop Grafana and delete volume
info "Stopping Grafana..."
$COMPOSE_CMD rm -sf grafana 2>&1
info "Deleting grafana-data volume..."
docker volume rm cdc-on-ec2-docker_grafana-data 2>/dev/null || true

# Step 4: Start Grafana
info "Starting Grafana..."
$COMPOSE_CMD up -d grafana 2>&1
info "Grafana refreshed — $rendered dashboard(s) rendered"
