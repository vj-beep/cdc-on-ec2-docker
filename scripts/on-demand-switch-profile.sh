#!/usr/bin/env bash
# =============================================================================
# on-demand-switch-profile.sh — Switch Between Snapshot and Streaming Tuning Profiles
#
# Copies tuning-related variables from the selected profile into the active
# .env file, preserving infrastructure variables (IPs, endpoints, passwords).
#
# Usage:
#   ./scripts/on-demand-switch-profile.sh snapshot    # Optimize for initial data load
#   ./scripts/on-demand-switch-profile.sh streaming   # Optimize for steady-state CDC (sub-second capable)
#
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# ---------------------------------------------------------------------------
# Validate arguments
# ---------------------------------------------------------------------------
if [[ $# -ne 1 ]] || [[ "$1" != "snapshot" && "$1" != "streaming" ]]; then
    echo "Usage: $0 {snapshot|streaming}"
    echo ""
    echo "  snapshot   - Optimize for initial data load / bulk snapshot"
    echo "  streaming  - Optimize for steady-state CDC (sub-second capable)"
    exit 1
fi

PROFILE="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${REPO_ROOT}/.env"
PROFILE_FILE="${REPO_ROOT}/profiles/.env.${PROFILE}"

# ---------------------------------------------------------------------------
# Validate files exist
# ---------------------------------------------------------------------------
if [[ ! -f "${PROFILE_FILE}" ]]; then
    error "Profile file not found: ${PROFILE_FILE}"
    exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
    error ".env file not found: ${ENV_FILE}"
    error "Copy .env.template to .env and fill in your infrastructure values first."
    exit 1
fi

# ---------------------------------------------------------------------------
# Extract tuning variable names from the profile file
# (Lines matching KEY=VALUE, ignoring comments and blank lines)
# ---------------------------------------------------------------------------
TUNING_VARS=()
while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue
    # Extract variable name (everything before the first '=')
    VAR_NAME="${line%%=*}"
    # Trim whitespace
    VAR_NAME="$(echo "${VAR_NAME}" | xargs)"
    [[ -n "${VAR_NAME}" ]] && TUNING_VARS+=("${VAR_NAME}")
done < "${PROFILE_FILE}"

if [[ ${#TUNING_VARS[@]} -eq 0 ]]; then
    error "No tuning variables found in ${PROFILE_FILE}"
    exit 1
fi

# ---------------------------------------------------------------------------
# Back up current .env
# ---------------------------------------------------------------------------
BACKUP="${ENV_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
cp "${ENV_FILE}" "${BACKUP}"
info "Backed up current .env to ${BACKUP}"

# ---------------------------------------------------------------------------
# Apply profile: update existing vars or append new ones
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Switching to '${PROFILE}' profile${NC}"
echo -e "${BOLD}======================================${NC}"

UPDATED=0
ADDED=0

while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "${line}" ]] && continue
    [[ "${line}" =~ ^[[:space:]]*# ]] && continue

    VAR_NAME="${line%%=*}"
    VAR_NAME="$(echo "${VAR_NAME}" | xargs)"
    VAR_VALUE="${line#*=}"

    [[ -z "${VAR_NAME}" ]] && continue

    if grep -q "^${VAR_NAME}=" "${ENV_FILE}"; then
        # Variable exists in .env — update it
        OLD_VALUE=$(grep "^${VAR_NAME}=" "${ENV_FILE}" | head -1 | cut -d'=' -f2-)
        if [[ "${OLD_VALUE}" != "${VAR_VALUE}" ]]; then
            # Use a delimiter that won't conflict with values
            sed -i "s|^${VAR_NAME}=.*|${VAR_NAME}=${VAR_VALUE}|" "${ENV_FILE}"
            echo -e "  ${GREEN}Updated${NC}  ${VAR_NAME}=${VAR_VALUE}  (was: ${OLD_VALUE})"
            UPDATED=$((UPDATED + 1))
        else
            echo -e "  ${YELLOW}No change${NC}  ${VAR_NAME}=${VAR_VALUE}"
        fi
    else
        # Variable does not exist — append it
        echo "${VAR_NAME}=${VAR_VALUE}" >> "${ENV_FILE}"
        echo -e "  ${GREEN}Added${NC}    ${VAR_NAME}=${VAR_VALUE}"
        ADDED=$((ADDED + 1))
    fi
done < "${PROFILE_FILE}"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}======================================${NC}"
echo -e "  Profile:   ${GREEN}${PROFILE}${NC}"
echo -e "  Updated:   ${UPDATED} variable(s)"
echo -e "  Added:     ${ADDED} variable(s)"
echo -e "  Backup:    ${BACKUP}"
echo ""
if [[ "${PROFILE}" == "snapshot" ]]; then
    warn "Snapshot profile is optimized for bulk data loading."
    warn "Switch to 'streaming' profile after the initial snapshot completes."
    echo ""
fi

# ---------------------------------------------------------------------------
# Show diff and prompt for distribute + restart
# ---------------------------------------------------------------------------
echo -e "${BOLD}Changes applied:${NC}"
echo "--------------------------------------"
diff --color=always "${BACKUP}" "${ENV_FILE}" || true
echo "--------------------------------------"
echo ""

echo -n -e "${BOLD}Distribute .env to all nodes and restart services? [y/N]:${NC} "
read -r CONFIRM

if [[ "${CONFIRM}" =~ ^[Yy]$ ]]; then
    echo ""
    info "Distributing .env to all nodes..."
    "${SCRIPT_DIR}/2b-distribute-env.sh"

    echo ""
    # Source .env for instance IDs / IPs and dispatch mode
    source "${ENV_FILE}"
    AWS_REGION=${AWS_REGION:-us-east-1}
    DISPATCH_MODE="${DISPATCH_MODE:-ssm}"

    info "Restarting services on all nodes (DISPATCH_MODE=${DISPATCH_MODE})..."

    DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
    DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER}/cdc-on-ec2-docker}"

    RESTART_FAILED=()
    for NODE in broker1 broker2 broker3 connect monitor; do
        if [[ "${DISPATCH_MODE}" == "ssh" ]]; then
            SSH_KEY="${SSH_KEY_PATH:-}"
            case "${NODE}" in
                broker1) NODE_IP="${BROKER_1_IP}" ;;
                broker2) NODE_IP="${BROKER_2_IP}" ;;
                broker3) NODE_IP="${BROKER_3_IP}" ;;
                connect) NODE_IP="${CONNECT_1_IP}" ;;
                monitor) NODE_IP="${MONITOR_1_IP}" ;;
            esac
            info "Restarting ${NODE} (${NODE_IP}) via SSH..."
            if ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
                   "${DEPLOY_USER}@${NODE_IP}" \
                   "cd ${DEPLOY_DIR} && bash scripts/5-start-node.sh --local ${NODE}" 2>&1 | tail -3; then
                info "${NODE} restarted ✅"
            else
                error "${NODE} restart failed"
                RESTART_FAILED+=("${NODE}")
            fi
        else
            case "${NODE}" in
                broker1) INSTANCE_ID="${BROKER_1_INSTANCE_ID}" ;;
                broker2) INSTANCE_ID="${BROKER_2_INSTANCE_ID}" ;;
                broker3) INSTANCE_ID="${BROKER_3_INSTANCE_ID}" ;;
                connect) INSTANCE_ID="${CONNECT_1_INSTANCE_ID}" ;;
                monitor) INSTANCE_ID="${MONITOR_1_INSTANCE_ID}" ;;
            esac
            if [[ -z "${INSTANCE_ID}" ]]; then
                warn "No instance ID for ${NODE} — skipping"
                RESTART_FAILED+=("${NODE}")
                continue
            fi

            info "Restarting ${NODE} (${INSTANCE_ID}) via SSM..."
            CMD_ID=$(aws ssm send-command \
                --region "${AWS_REGION}" \
                --instance-ids "${INSTANCE_ID}" \
                --document-name "AWS-RunShellScript" \
                --parameters "commands=[\"cd ${DEPLOY_DIR} && bash scripts/5-start-node.sh --local ${NODE}\"]" \
                --query 'Command.CommandId' \
                --output text 2>/dev/null)

            if [[ -z "${CMD_ID}" || "${CMD_ID}" == "None" ]]; then
                error "Failed to send restart command to ${NODE}"
                RESTART_FAILED+=("${NODE}")
                continue
            fi

            TIMEOUT=180
            ELAPSED=0
            STATUS="InProgress"
            while [[ "${STATUS}" == "InProgress" && ${ELAPSED} -lt ${TIMEOUT} ]]; do
                sleep 5
                ELAPSED=$((ELAPSED + 5))
                STATUS=$(aws ssm get-command-invocation \
                    --region "${AWS_REGION}" \
                    --command-id "${CMD_ID}" \
                    --instance-id "${INSTANCE_ID}" \
                    --query 'Status' \
                    --output text 2>/dev/null)
            done

            if [[ "${STATUS}" == "Success" ]]; then
                info "${NODE} restarted ✅"
            else
                error "${NODE} restart failed (status: ${STATUS})"
                RESTART_FAILED+=("${NODE}")
            fi
        fi
    done

    echo ""
    if [[ ${#RESTART_FAILED[@]} -eq 0 ]]; then
        info "All nodes restarted with '${PROFILE}' profile. ✅"
    else
        error "Failed to restart: ${RESTART_FAILED[*]}"
        if [[ "${DISPATCH_MODE}" == "ssh" ]]; then
            echo "  Troubleshoot: ssh -i ${SSH_KEY_PATH} ${DEPLOY_USER}@<node-ip>"
        else
            echo "  Troubleshoot: aws ssm start-session --target <instance-id>"
        fi
    fi

    echo ""
    warn "Connector configs are set at deploy time — worker restart alone is not enough."
    warn "Redeploy connectors now to apply new batch/queue sizes to running connectors:"
    echo "  ./scripts/6-deploy-connectors.sh"
else
    echo ""
    info "Skipped. To apply manually:"
    echo "  1. ./scripts/2b-distribute-env.sh"
    echo "  2. Restart on each node:"
    echo "     SSM mode:  ./scripts/5-start-node.sh broker1 (dispatches via SSM)"
    echo "     SSH mode:  ssh into each node, then: bash scripts/5-start-node.sh --local broker1"
    echo "     Repeat for broker2, broker3, connect, monitor"
    echo "  3. Redeploy connectors to apply new batch/queue sizes:"
    echo "     ./scripts/6-deploy-connectors.sh"
fi
