#!/bin/bash
###############################################################################
# teardown-reset-all-nodes.sh
# Comprehensive cluster reset for fresh re-deployment (via AWS SSM)
#
# Executes teardown REMOTELY on all 5 EC2 nodes via AWS Systems Manager.
# Run this from the jumpbox — it SSMs into each node to perform cleanup.
#
# Usage: teardown-reset-all-nodes.sh [OPTIONS] [broker1|broker2|broker3|connect|monitor|all]
#
# Options:
#   -v, --verbose    Show detailed SSM command output
#   -q, --quiet      Suppress non-essential output
#   -y, --yes        Skip confirmation prompt (use with caution)
#
# Examples:
#   teardown-reset-all-nodes.sh --verbose              # All nodes, verbose
#   teardown-reset-all-nodes.sh -v broker1             # Reset broker1 only
#   teardown-reset-all-nodes.sh --quiet all            # All nodes, quiet mode
#   teardown-reset-all-nodes.sh -y broker1 broker2     # No confirm, brokers only
#
# What it does (per node, via SSM):
#   1. Stop all Docker containers gracefully (docker compose down)
#   2. Remove containers and networks
#   3. Clean Kafka data directories (/data/kafka)
#   4. Remove Docker volumes (persisted state)
#   5. Remove Docker images (for fresh builds)
#   6. Clear application logs
#   7. Prune Docker system
#
# Result: Nodes are ready for fresh deployment (./scripts/5-start-node.sh)
#
# WARNING: This is DESTRUCTIVE and cannot be undone!
# - All Kafka data is lost (topics, partitions, offsets)
# - All connector state is lost
# - Docker images must be rebuilt
###############################################################################

set -euo pipefail

# Load .env for instance IDs and version variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ -f "$SCRIPT_DIR/.env" ]]; then
  set +u; set -a; source "$SCRIPT_DIR/.env"; set +a; set -u
fi
CP_VERSION="${CP_VERSION:-8.0.0}"
CONTROL_CENTER_VERSION="${CONTROL_CENTER_VERSION:-2.2.0}"
AWS_REGION="${AWS_REGION:-us-east-1}"

# Color output
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
GRAY='\033[0;37m'
BOLD='\033[1m'
NC='\033[0m'

# Default settings
VERBOSE=false
QUIET=false
SKIP_CONFIRM=false
NODE_TYPES=()

# Parse options
while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose) VERBOSE=true; shift ;;
    -q|--quiet) QUIET=true; shift ;;
    -y|--yes) SKIP_CONFIRM=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS] [node-type ...]"
      echo ""
      echo "Options:"
      echo "  -v, --verbose    Show detailed SSM command output"
      echo "  -q, --quiet      Suppress non-essential output"
      echo "  -y, --yes        Skip confirmation prompt"
      echo "  -h, --help       Show this help message"
      echo ""
      echo "Node types:"
      echo "  broker1, broker2, broker3, connect, monitor, all (default)"
      exit 0
      ;;
    broker1|broker2|broker3|connect|monitor|all)
      NODE_TYPES+=("$1"); shift ;;
    *)
      echo "❌ Invalid option or node type: $1" >&2
      echo "Usage: $0 [OPTIONS] [broker1|broker2|broker3|connect|monitor|all]" >&2
      exit 1
      ;;
  esac
done

# Default to all if no node specified
if [[ ${#NODE_TYPES[@]} -eq 0 ]]; then
  NODE_TYPES=("all")
fi

# Expand "all" into individual nodes
NODES=()
for nt in "${NODE_TYPES[@]}"; do
  if [[ "$nt" == "all" ]]; then
    NODES=(broker1 broker2 broker3 connect monitor)
    break
  else
    NODES+=("$nt")
  fi
done

# Map node types to instance IDs
get_instance_id() {
  local node="$1"
  case "$node" in
    broker1) echo "${BROKER_1_INSTANCE_ID:-${BROKER_1_ID:-}}" ;;
    broker2) echo "${BROKER_2_INSTANCE_ID:-${BROKER_2_ID:-}}" ;;
    broker3) echo "${BROKER_3_INSTANCE_ID:-${BROKER_3_ID:-}}" ;;
    connect) echo "${CONNECT_1_INSTANCE_ID:-${CONNECT_1_ID:-}}" ;;
    monitor) echo "${MONITOR_1_INSTANCE_ID:-${MONITOR_1_ID:-}}" ;;
  esac
}

# Validate instance IDs
validate_instance_id() {
  local id="$1"
  local node="$2"
  if [[ -z "$id" ]]; then
    echo -e "${RED}❌ No instance ID found for $node${NC}" >&2
    echo "   Set ${node^^}_INSTANCE_ID in .env or pass IDs as arguments" >&2
    return 1
  fi
  if [[ ${#id} -ne 19 ]] || ! [[ "$id" =~ ^i-[0-9a-f]{17}$ ]]; then
    echo -e "${RED}❌ Invalid instance ID for $node: $id${NC}" >&2
    return 1
  fi
}

# Check prerequisites
if ! command -v aws &>/dev/null; then
  echo "❌ AWS CLI not found. Install with: pip install awscli"
  exit 1
fi

# Validate all instance IDs before proceeding
declare -A NODE_INSTANCE_MAP
for node in "${NODES[@]}"; do
  id=$(get_instance_id "$node")
  validate_instance_id "$id" "$node" || exit 1
  NODE_INSTANCE_MAP["$node"]="$id"
done

# Build the teardown command for a given node type
build_teardown_command() {
  local node="$1"

  # Images to remove per node type
  local images_cmd=""
  case "$node" in
    broker1|broker2|broker3)
      images_cmd="docker rmi -f confluentinc/cp-server:${CP_VERSION} 2>/dev/null || true"
      ;;
    connect)
      images_cmd="docker rmi -f cdc-connect:${CP_VERSION} confluentinc/cp-server-connect:${CP_VERSION} confluentinc/cp-schema-registry:${CP_VERSION} confluentinc/cp-kafka-rest:${CP_VERSION} 2>/dev/null || true"
      ;;
    monitor)
      images_cmd="docker rmi -f confluentinc/cp-enterprise-control-center-next-gen:${CONTROL_CENTER_VERSION} confluentinc/cp-ksqldb-server:${CP_VERSION} confluentinc/cp-kafka-rest:${CP_VERSION} prom/prometheus:latest grafana/grafana:latest prom/alertmanager:latest 2>/dev/null || true"
      ;;
  esac

  cat <<EOFCMD
set -e
echo "=== Teardown starting on \$(hostname) ==="

# Step 1: Stop containers via docker compose
echo "[1/7] Stopping Docker containers..."
cd /home/ec2-user/cdc-on-ec2-docker 2>/dev/null && docker compose down --remove-orphans 2>/dev/null || true

# Step 2: Force-remove any remaining containers
echo "[2/7] Removing lingering containers..."
docker ps -aq | xargs -r docker rm -f 2>/dev/null || true

# Step 3: Clean Kafka data directory
echo "[3/7] Cleaning Kafka data directory..."
KAFKA_DATA_DIR="\${KAFKA_DATA_DIR:-/data/kafka}"
if [[ -d "\$KAFKA_DATA_DIR" ]]; then
  DATA_SIZE=\$(du -sh \$KAFKA_DATA_DIR 2>/dev/null | cut -f1)
  echo "   Removing \$DATA_SIZE from \$KAFKA_DATA_DIR"
  sudo rm -rf \$KAFKA_DATA_DIR/*
  sudo mkdir -p \$KAFKA_DATA_DIR
  sudo chown ec2-user:ec2-user \$KAFKA_DATA_DIR
else
  echo "   \$KAFKA_DATA_DIR not found (OK for fresh node)"
fi

# Step 4: Remove Docker volumes
echo "[4/7] Removing Docker volumes..."
docker volume prune -f 2>/dev/null || true

# Step 5: Remove Docker images
echo "[5/7] Removing Docker images..."
${images_cmd}

# Step 6: Clean logs and temp files
echo "[6/7] Cleaning logs and temp files..."
rm -rf /home/ec2-user/.docker/logs /home/ec2-user/.docker/tmp /tmp/kafka* /tmp/zk* 2>/dev/null || true

# Step 7: Prune Docker system
echo "[7/7] Pruning Docker system..."
docker system prune -f 2>/dev/null || true

# Final verification
REMAINING=\$(docker ps -a --format "{{.Names}}" 2>/dev/null | wc -l)
echo ""
echo "=== Teardown complete ==="
echo "Remaining containers: \$REMAINING"
echo "Remaining images: \$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | wc -l)"
echo "Kafka dir exists: \$(test -d \$KAFKA_DATA_DIR && echo 'yes (empty)' || echo 'no')"
EOFCMD
}

# Execute command on a node via SSM and wait for result
run_ssm_command() {
  local node="$1"
  local instance_id="$2"
  local command="$3"

  # Base64-encode the script to avoid JSON/quote escaping issues
  local encoded
  encoded=$(echo "$command" | base64 -w 0)

  # Send command via SSM — decode and execute on the remote node
  local command_id
  command_id=$(aws ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"echo $encoded | base64 -d | bash\"]" \
    --timeout-seconds 120 \
    --region "$AWS_REGION" \
    --query 'Command.CommandId' \
    --output text 2>/dev/null || echo "")

  if [[ -z "$command_id" ]]; then
    echo -e "  ${RED}✗ SSM send-command failed for $node ($instance_id)${NC}"
    return 1
  fi

  # Wait for command to complete
  local max_wait=60
  local waited=0
  local status=""

  while [[ $waited -lt $max_wait ]]; do
    sleep 2
    waited=$((waited + 2))

    status=$(aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$instance_id" \
      --region "$AWS_REGION" \
      --query 'Status' \
      --output text 2>/dev/null || echo "Pending")

    case "$status" in
      Success)
        if [[ "$VERBOSE" == true ]]; then
          local output
          output=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --region "$AWS_REGION" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null || echo "")
          echo "$output" | sed 's/^/    /'
        else
          # Show just the summary lines
          local output
          output=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --region "$AWS_REGION" \
            --query 'StandardOutputContent' \
            --output text 2>/dev/null || echo "")
          echo "$output" | grep -E "^(===|Remaining|Kafka)" | sed 's/^/    /'
        fi
        return 0
        ;;
      Failed|TimedOut|Cancelled)
        echo -e "  ${RED}✗ Command $status on $node${NC}"
        if [[ "$VERBOSE" == true ]]; then
          local err_output
          err_output=$(aws ssm get-command-invocation \
            --command-id "$command_id" \
            --instance-id "$instance_id" \
            --region "$AWS_REGION" \
            --query 'StandardErrorContent' \
            --output text 2>/dev/null || echo "")
          [[ -n "$err_output" ]] && echo "$err_output" | sed 's/^/    /'
        fi
        return 1
        ;;
    esac
  done

  echo -e "  ${YELLOW}⚠ Timeout waiting for $node (command may still be running)${NC}"
  echo "    Command ID: $command_id"
  return 1
}

# Confirmation prompt
if [[ "$SKIP_CONFIRM" != true ]]; then
  echo ""
  echo -e "${RED}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${RED}║ WARNING: DESTRUCTIVE OPERATION - POINT OF NO RETURN                    ║${NC}"
  echo -e "${RED}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo "This will completely reset the following nodes via SSM:"
  for node in "${NODES[@]}"; do
    echo "  • $node (${NODE_INSTANCE_MAP[$node]})"
  done
  echo ""
  echo -e "${RED}Data that will be PERMANENTLY DELETED:${NC}"
  echo "  • All Docker containers and images"
  echo "  • All Kafka data (topics, partitions, offsets, replication logs)"
  echo "  • All connector state and configuration"
  echo "  • All application logs and temporary files"
  echo "  • All Docker volumes and persisted state"
  echo ""
  echo -e "${YELLOW}This operation CANNOT be undone.${NC}"
  echo ""
  read -p "Type 'yes' to proceed, or press Ctrl+C to abort: " confirm

  if [[ "$confirm" != "yes" ]]; then
    echo "❌ Aborted"
    exit 0
  fi
fi

echo ""
echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║     CDC deployment — Cluster Teardown (via AWS SSM)                     ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Execute teardown on each node
START_TIME=$(date +%s)
SUCCESS_COUNT=0
FAIL_COUNT=0

for node in "${NODES[@]}"; do
  instance_id="${NODE_INSTANCE_MAP[$node]}"
  echo -e "${BLUE}━━━ $node ($instance_id) ━━━${NC}"

  command=$(build_teardown_command "$node")

  if run_ssm_command "$node" "$instance_id" "$command"; then
    echo -e "  ${GREEN}✓ $node reset complete${NC}"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo -e "  ${RED}✗ $node reset failed${NC}"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo ""
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

# Summary
echo ""
if [[ $FAIL_COUNT -eq 0 ]]; then
  echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${GREEN}║ ALL NODES RESET SUCCESSFULLY                                             ║${NC}"
  echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
else
  echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${YELLOW}║ TEARDOWN COMPLETED WITH ERRORS                                           ║${NC}"
  echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════════════════╝${NC}"
fi
echo ""
echo "Reset Summary:"
echo "  • Nodes attempted: ${#NODES[@]}"
echo "  • Succeeded: $SUCCESS_COUNT"
[[ $FAIL_COUNT -gt 0 ]] && echo -e "  • ${RED}Failed: $FAIL_COUNT${NC}"
echo "  • Time taken: ${DURATION}s"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo "  1. Rebuild Connect image:"
echo "     ./scripts/4-build-connect.sh"
echo ""
echo "  2. Start nodes (order matters — brokers first):"
for node in "${NODES[@]}"; do
  echo "     ./scripts/5-start-node.sh $node"
done
echo ""
echo -e "${YELLOW}Note:${NC} First start after teardown takes 5-10 min (Docker image pulls)"
echo ""
