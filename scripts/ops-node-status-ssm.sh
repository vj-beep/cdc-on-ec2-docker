#!/bin/bash
###############################################################################
# Node Status Dashboard — AWS Systems Manager Edition
#
# Displays all 5 EC2 nodes and their Confluent Platform service status.
# Uses AWS SSM to query nodes remotely (no SSH needed, works from anywhere).
# Shows which services are running/stopped with color coding.
#
# Usage (from your local machine):
#   bash scripts/node-status-ssm.sh <b1-id> <b2-id> <b3-id> <c1-id> <m1-id>
#
#   Example:
#   bash scripts/node-status-ssm.sh i-0abc1234 i-0def5678 i-0ghi9012 i-0jkl3456 i-0mno7890
#
# Or set environment variables:
#   export BROKER_1_ID=i-0abc1234
#   export BROKER_2_ID=i-0def5678
#   export BROKER_3_ID=i-0ghi9012
#   export CONNECT_1_ID=i-0jkl3456
#   export MONITOR_1_ID=i-0mno7890
#   bash scripts/node-status-ssm.sh
#
# Prerequisites:
#   - AWS CLI v2 configured with credentials
#   - EC2 instances have IAM role with SSM permissions (AmazonSSMManagedInstanceCore)
#   - Instances are running and SSM agent is active
#
# Get instance IDs from AWS Console or CLI:
#   aws ec2 describe-instances --filters "Name=tag:Name,Values=broker*" --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`].Value|[0]]'
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

# Parse arguments or use environment variables from .env
if [ $# -lt 5 ]; then
  # Try to load from .env first
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
    echo "Get instance IDs:"
    echo "  aws ec2 describe-instances --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==\`Name\`].Value|[0]]' --output table"
    exit 1
  fi
else
  BROKER_1_ID="$1"
  BROKER_2_ID="$2"
  BROKER_3_ID="$3"
  CONNECT_1_ID="$4"
  MONITOR_1_ID="$5"
fi

# Validate all instance IDs
validate_instance_id "$BROKER_1_ID"
validate_instance_id "$BROKER_2_ID"
validate_instance_id "$BROKER_3_ID"
validate_instance_id "$CONNECT_1_ID"
validate_instance_id "$MONITOR_1_ID"

# Check AWS CLI
if ! command -v aws &>/dev/null; then
  echo "❌ AWS CLI not found. Install with: pip install awscli"
  exit 1
fi

# Define nodes (ordered arrays for predictable display)
NODE_NAMES=("Node 1 — Broker 1" "Node 2 — Broker 2" "Node 3 — Broker 3" "Node 4 — Connect + Schema Registry" "Node 5 — Monitoring & Control")
NODE_IDS=("$BROKER_1_ID" "$BROKER_2_ID" "$BROKER_3_ID" "$CONNECT_1_ID" "$MONITOR_1_ID")

echo ""
echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║     CDC deployment — Confluent Platform Node Status (via AWS SSM)      ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Function to get service status via SSM
get_node_status() {
  local node_name="$1"
  local instance_id="$2"

  echo -e "${BOLD}${BLUE}─ $node_name ($instance_id)${NC}"

  # Send command via SSM to check repo and docker compose status
  local command_id
  command_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["cd /home/ec2-user/cdc-on-ec2-docker && docker compose ps --format json 2>&1"]' \
    --region "${AWS_REGION:-us-east-1}" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null || echo "")

  if [ -z "$command_id" ]; then
    echo -e "  ${RED}✗ UNREACHABLE${NC} (SSM send-command failed)"
    echo ""
    return 0
  fi

  # Wait for command to complete (with retries for slow networks)
  local max_retries=30
  local retry_count=0
  local output=""

  while [ $retry_count -lt $max_retries ]; do
    sleep 1
    output=$(aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --region "${AWS_REGION:-us-east-1}" \
      --query 'StandardOutputContent' \
      --output text 2>/dev/null || echo "")

    # If we have output or command status shows it completed, break
    if [ -n "$output" ] && ! [[ "$output" =~ "not yet invoked" ]]; then
      break
    fi
    retry_count=$((retry_count + 1))
  done

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
  get_node_status "${NODE_NAMES[$i]}" "${NODE_IDS[$i]}"
done

echo -e "${BOLD}${BLUE}Legend:${NC}"
echo -e "  ${GREEN}●${NC} = Running | ${RED}●${NC} = Stopped | ${YELLOW}●${NC} = Unknown"
echo ""
echo -e "${GREY}Tip: To stream logs from a node, run:${NC}"
echo -e "  ${GREY}aws ssm start-session --target <instance-id>${NC}"
echo -e "  ${GREY}cd cdc-on-ec2-docker && docker compose logs -f <service>${NC}"
echo ""
