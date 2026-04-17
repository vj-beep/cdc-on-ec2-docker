#!/bin/bash
###############################################################################
# Node Status Dashboard
#
# Displays all 5 EC2 nodes and their Confluent Platform service status.
# Supports both SSM dispatch (default) and SSH dispatch modes.
#
# Usage (auto-detects DISPATCH_MODE from .env):
#   bash scripts/ops-node-status-ssm.sh
#
# SSM mode (default): queries nodes via AWS Systems Manager
#   Requires: AWS CLI, EC2 IAM role with AmazonSSMManagedInstanceCore
#   Uses: BROKER_*_INSTANCE_ID / CONNECT_1_INSTANCE_ID / MONITOR_1_INSTANCE_ID
#
# SSH mode (DISPATCH_MODE=ssh in .env): queries nodes via SSH
#   Requires: SSH_KEY_PATH set in .env, key authorised on all nodes
#   Uses: BROKER_*_IP / CONNECT_1_IP / MONITOR_1_IP
#
# Or pass 5 instance IDs directly (SSM mode only):
#   bash scripts/ops-node-status-ssm.sh i-0abc1234 i-0def5678 i-0ghi9012 i-0jkl3456 i-0mno7890
###############################################################################

set -uo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Validate instance IDs (must be 19 chars: i-<17 hex chars>)
validate_instance_id() {
  local id="$1"
  if [ ${#id} -ne 19 ] || ! [[ "$id" =~ ^i-[0-9a-f]{17}$ ]]; then
    echo "❌ Invalid instance ID format: $id (expected: i-0abc1234def56789)"
    exit 1
  fi
}

# Load .env if it exists
ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.env"
if [ -f "$ENV_FILE" ]; then
  set +u  # Allow unset variables during source
  source "$ENV_FILE"
  set -u
fi

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER}/cdc-on-ec2-docker}"

# ---------------------------------------------------------------------------
# SSH mode: use IPs directly
# ---------------------------------------------------------------------------
if [[ "$DISPATCH_MODE" == "ssh" ]]; then
  SSH_KEY="${SSH_KEY_PATH:-}"
  if [[ -z "$SSH_KEY" ]]; then
    echo "❌ SSH_KEY_PATH not set in .env (required for DISPATCH_MODE=ssh)"
    exit 1
  fi
  if [[ ! -f "$SSH_KEY" ]]; then
    echo "❌ SSH key not found: $SSH_KEY"
    exit 1
  fi
  # Map names to IPs for SSH mode
  NODE_NAMES=("Node 1 — Broker 1" "Node 2 — Broker 2" "Node 3 — Broker 3" "Node 4 — Connect + Schema Registry" "Node 5 — Monitoring & Control")
  NODE_ADDRS=("${BROKER_1_IP:-}" "${BROKER_2_IP:-}" "${BROKER_3_IP:-}" "${CONNECT_1_IP:-}" "${MONITOR_1_IP:-}")

  # Validate IPs set
  for ip in "${NODE_ADDRS[@]}"; do
    if [[ -z "$ip" ]]; then
      echo "❌ One or more node IPs not set in .env — check BROKER_*_IP, CONNECT_1_IP, MONITOR_1_IP"
      exit 1
    fi
  done
else
  # ---------------------------------------------------------------------------
  # SSM mode: use instance IDs
  # ---------------------------------------------------------------------------
  # Check AWS CLI
  if ! command -v aws &>/dev/null; then
    echo "❌ AWS CLI not found. Install with: pip install awscli"
    exit 1
  fi

  # Parse arguments or use environment variables from .env
  if [ $# -lt 5 ]; then
    BROKER_1_ID="${BROKER_1_INSTANCE_ID:-${BROKER_1_ID:-}}"
    BROKER_2_ID="${BROKER_2_INSTANCE_ID:-${BROKER_2_ID:-}}"
    BROKER_3_ID="${BROKER_3_INSTANCE_ID:-${BROKER_3_ID:-}}"
    CONNECT_1_ID="${CONNECT_1_INSTANCE_ID:-${CONNECT_1_ID:-}}"
    MONITOR_1_ID="${MONITOR_1_INSTANCE_ID:-${MONITOR_1_ID:-}}"

    if [ -z "$BROKER_1_ID" ] || [ -z "$MONITOR_1_ID" ]; then
      echo "Usage:"
      echo "  bash scripts/ops-node-status-ssm.sh [options]"
      echo ""
      echo "Options:"
      echo "  (no args)  — Read instance IDs from .env file (recommended)"
      echo "  <ids>      — Pass 5 instance IDs: <b1-id> <b2-id> <b3-id> <c1-id> <m1-id>"
      echo ""
      echo "Example:"
      echo "  bash scripts/ops-node-status-ssm.sh i-0abc1234 i-0def5678 i-0ghi9012 i-0jkl3456 i-0mno7890"
      echo ""
      echo "SSH mode: set DISPATCH_MODE=ssh and SSH_KEY_PATH in .env — no instance IDs needed."
      exit 1
    fi
  else
    BROKER_1_ID="$1"
    BROKER_2_ID="$2"
    BROKER_3_ID="$3"
    CONNECT_1_ID="$4"
    MONITOR_1_ID="$5"
  fi

  validate_instance_id "$BROKER_1_ID"
  validate_instance_id "$BROKER_2_ID"
  validate_instance_id "$BROKER_3_ID"
  validate_instance_id "$CONNECT_1_ID"
  validate_instance_id "$MONITOR_1_ID"

  NODE_NAMES=("Node 1 — Broker 1" "Node 2 — Broker 2" "Node 3 — Broker 3" "Node 4 — Connect + Schema Registry" "Node 5 — Monitoring & Control")
  NODE_ADDRS=("$BROKER_1_ID" "$BROKER_2_ID" "$BROKER_3_ID" "$CONNECT_1_ID" "$MONITOR_1_ID")
fi


echo ""
echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║     CDC deployment — Confluent Platform Node Status (via AWS SSM)      ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Display active tuning profile from .env
echo -e "${BOLD}${BLUE}─ Tuning Profile${NC}"
FETCH_MIN="${CONNECT_CONSUMER_FETCH_MIN_BYTES:-}"
if [ -z "$FETCH_MIN" ]; then
  echo -e "  ${GREY}● Unknown${NC} (CONNECT_CONSUMER_FETCH_MIN_BYTES not in .env)"
elif [ "$FETCH_MIN" = "1" ]; then
  echo -e "  ${GREEN}● Streaming${NC} (low-latency CDC)"
else
  echo -e "  ${YELLOW}● Snapshot${NC} (high-throughput bulk load)"
fi
echo ""

# Function to get service status from a node (SSH or SSM)
get_node_status() {
  local node_name="$1"
  local node_addr="$2"   # instance ID (ssm) or IP (ssh)

  echo -e "${BOLD}${BLUE}─ $node_name ($node_addr)${NC}"

  local output=""

  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    output=$(ssh -i "${SSH_KEY_PATH}" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "${DEPLOY_USER}@${node_addr}" \
      "cd ${DEPLOY_DIR} && docker compose ps --format json 2>&1" 2>/dev/null || echo "")
    if [[ -z "$output" ]]; then
      echo -e "  ${RED}✗ UNREACHABLE${NC} (SSH connection failed)"
      echo ""
      return 0
    fi
  else
    local command_id
    command_id=$(aws ssm send-command \
      --instance-ids "$node_addr" \
      --document-name "AWS-RunShellScript" \
      --parameters "commands=[\"cd ${DEPLOY_DIR} && docker compose ps --format json 2>&1\"]" \
      --region "${AWS_REGION:-us-east-1}" \
      --query 'Command.CommandId' \
      --output text 2>/dev/null || echo "")

    if [ -z "$command_id" ]; then
      echo -e "  ${RED}✗ UNREACHABLE${NC} (SSM send-command failed)"
      echo ""
      return 0
    fi

    local max_retries=30
    local retry_count=0

    while [ $retry_count -lt $max_retries ]; do
      sleep 1
      output=$(aws ssm get-command-invocation \
        --command-id "$command_id" \
        --instance-id "$node_addr" \
        --region "${AWS_REGION:-us-east-1}" \
        --query 'StandardOutputContent' \
        --output text 2>/dev/null || echo "")

      if [ -n "$output" ] && ! [[ "$output" =~ "not yet invoked" ]]; then
        break
      fi
      retry_count=$((retry_count + 1))
    done
  fi

  # Parse output
  if [ -z "$output" ]; then
    echo -e "  ${RED}✗ NO OUTPUT${NC} (command may still be running or instance unreachable)"
    echo ""
    return 0
  fi

  # Check for Docker errors or repo issues
  if [[ "$output" =~ "No such file or directory" ]] || [[ "$output" =~ "docker: not found" ]]; then
    echo -e "  ${YELLOW}⚠ PHASE 2b PENDING${NC} (public repo not cloned yet)"
    echo ""
    return 0
  fi

  if [[ "$output" =~ "permission denied" ]] || [[ "$output" =~ "Cannot connect" ]]; then
    echo -e "  ${RED}✗ DOCKER ERROR${NC}: $(echo "$output" | head -1)"
    echo ""
    return 0
  fi

  # Parse docker compose ps --format json output (newline-delimited JSON)
  local running_count=0
  local stopped_count=0
  local running_services=()
  local stopped_services=()

  # Check if output is JSON (contains '{' and '"State"')
  if [[ "$output" =~ \{.*\"State\" ]]; then
    # Parse newline-delimited JSON objects
    while IFS= read -r line; do
      # Skip empty lines
      [ -z "$line" ] && continue

      # Extract Name and State from JSON object
      local name=$(echo "$line" | grep -o '"Name":"[^"]*' | head -1 | sed 's/"Name":"\(.*\)/\1/')
      local state=$(echo "$line" | grep -o '"State":"[^"]*' | head -1 | sed 's/"State":"\(.*\)/\1/')

      # Also extract Status which has human-readable format like "Up 18 minutes"
      local status=$(echo "$line" | grep -o '"Status":"[^"]*' | head -1 | sed 's/"Status":"\(.*\)/\1/')

      if [ -n "$name" ]; then
        # Use State field (running, exited, etc) or Status field for determination
        if [[ "$state" == "running" ]] || [[ "$status" =~ ^Up ]]; then
          ((running_count++))
          running_services+=("$name")
        else
          ((stopped_count++))
          stopped_services+=("$name")
        fi
      fi
    done <<< "$output"
  else
    # Fallback: parse table format, skip headers
    while IFS= read -r line; do
      # Skip header lines and empty lines
      if [ -z "$line" ] || [[ "$line" =~ ^NAME|^CONTAINER|^---|- ]]; then
        continue
      fi

      # Extract first field (service/container name)
      local service=$(echo "$line" | awk '{print $1}')
      # Extract status (look for "Up" or other status keywords)
      local status=$(echo "$line" | grep -o 'Up\|Exited\|Created\|Running\|Stopped\|Paused')

      if [ -n "$service" ] && [ -n "$status" ]; then
        if [[ "$status" =~ ^Up|Running ]]; then
          ((running_count++))
          running_services+=("$service")
        else
          ((stopped_count++))
          stopped_services+=("$service")
        fi
      fi
    done <<< "$output"
  fi

  # Display summary
  if [ $running_count -eq 0 ] && [ $stopped_count -eq 0 ]; then
    echo -e "  ${YELLOW}⚠ NO SERVICES${NC} (check instance status)"
  else
    if [ $running_count -gt 0 ]; then
      echo -e "  ${GREEN}✓ Running${NC}: $running_count services"
      for svc in "${running_services[@]}"; do
        echo -e "    ${GREEN}●${NC} $svc"
      done
    fi

    if [ $stopped_count -gt 0 ]; then
      echo -e "  ${RED}✗ Stopped${NC}: $stopped_count services"
      for svc in "${stopped_services[@]}"; do
        echo -e "    ${RED}●${NC} $svc"
      done
    fi
  fi

  echo ""
}

# Iterate through nodes
for i in "${!NODE_NAMES[@]}"; do
  get_node_status "${NODE_NAMES[$i]}" "${NODE_ADDRS[$i]}"
done

echo -e "${BOLD}${BLUE}Legend:${NC}"
echo -e "  ${GREEN}●${NC} = Running | ${RED}●${NC} = Stopped | ${YELLOW}●${NC} = Unknown"
echo ""
echo -e "${GREY}Tip: To stream logs from a node:${NC}"
if [[ "$DISPATCH_MODE" == "ssh" ]]; then
echo -e "  ${GREY}ssh -i ${SSH_KEY_PATH:-~/.ssh/id_rsa} ${DEPLOY_USER}@<node-ip>${NC}"
else
echo -e "  ${GREY}aws ssm start-session --target <instance-id>${NC}"
fi
echo -e "  ${GREY}cd ${DEPLOY_DIR} && docker compose logs -f <service>${NC}"
echo ""
