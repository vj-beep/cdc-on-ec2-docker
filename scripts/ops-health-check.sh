#!/bin/bash

# Health check script for CDC deployment deployment
# Validates readiness of all services before connector deployment
# Usage: ./scripts/ops-health-check.sh [--remote] or ./scripts/ops-health-check.sh --remote <node-ips>

set -e

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Defaults
REMOTE_MODE=false
REMOTE_NODES=()
TIMEOUT=5

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --remote)
      REMOTE_MODE=true
      shift
      # Collect all remaining args as node IPs
      REMOTE_NODES=("$@")
      break
      ;;
    --timeout)
      TIMEOUT=$2
      shift 2
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo -e "${BLUE}=== CDC deployment Health Check ===${NC}"
echo

# Function to check port
check_port() {
  local host=$1
  local port=$2
  local service=$3

  if timeout $TIMEOUT nc -z "$host" "$port" 2>/dev/null; then
    echo -e "${GREEN}✓${NC} $service listening on $host:$port"
    return 0
  else
    echo -e "${RED}✗${NC} $service NOT listening on $host:$port"
    return 1
  fi
}

# Function to check HTTP endpoint
check_http() {
  local url=$1
  local service=$2

  if timeout $TIMEOUT curl -s "$url" &>/dev/null; then
    echo -e "${GREEN}✓${NC} $service responding ($url)"
    return 0
  else
    echo -e "${RED}✗${NC} $service NOT responding ($url)"
    return 1
  fi
}

# Function to check service on local node
check_local() {
  local broker_port=$1
  local connect_port=$2

  echo -e "${BLUE}Local Node Checks:${NC}"

  # Brokers (check all 3 on ports 9091, 9092, 9093)
  # Port 9091 = controller, 9092 = client, 9093 = inter-broker
  check_port "localhost" "9093" "Broker (inter-broker 9093)" || true
  check_port "localhost" "9092" "Broker (client 9092)" || true

  # Connect REST API
  check_http "http://localhost:8083/connectors" "Connect REST API" || true

  # Schema Registry
  check_http "http://localhost:8081/subjects" "Schema Registry" || true

  # Control Center
  check_http "http://localhost:9021/api/version" "Control Center" || true

  # ksqlDB
  check_http "http://localhost:8088/info" "ksqlDB" || true

  # Prometheus (optional)
  check_http "http://localhost:9090/-/healthy" "Prometheus" || true

  # Grafana (optional)
  GRAFANA_PORT="${GRAFANA_PORT:-8080}"
  check_http "http://localhost:${GRAFANA_PORT}/api/health" "Grafana" || true
}

# Function to check service on remote nodes via AWS SSM
check_remote() {
  local node_ip=$1
  local node_name=$2
  local aws_region=${AWS_REGION:-us-east-1}

  echo -e "${BLUE}Remote Node: $node_name ($node_ip)${NC}"

  # Find instance ID by private IP
  local instance_id
  instance_id=$(aws ec2 describe-instances \
    --region "$aws_region" \
    --filters "Name=private-ip-address,Values=$node_ip" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null)

  if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
    echo -e "${RED}✗${NC} Could not find instance with IP $node_ip"
    return 1
  fi

  # Send health check command via SSM
  local cmd_id
  cmd_id=$(aws ssm send-command \
    --region "$aws_region" \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters 'commands=["nc -z localhost 9093 2>/dev/null && echo OK || echo FAIL"]' \
    --query 'Command.CommandId' \
    --output text 2>/dev/null)

  if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
    echo -e "${RED}✗${NC} Failed to send SSM command"
    return 1
  fi

  # Wait for command completion (up to 10 seconds)
  sleep 2
  local output
  output=$(aws ssm get-command-invocation \
    --region "$aws_region" \
    --command-id "$cmd_id" \
    --instance-id "$instance_id" \
    --query 'StandardOutputContent' \
    --output text 2>/dev/null)

  if [[ "$output" == "OK" ]]; then
    echo -e "${GREEN}✓${NC} Broker ready on $node_name"
    return 0
  else
    echo -e "${RED}✗${NC} Broker NOT ready on $node_name"
    return 1
  fi
}

# Main execution
if [[ $REMOTE_MODE == true ]]; then
  # Remote mode: check specified nodes
  if [[ ${#REMOTE_NODES[@]} -eq 0 ]]; then
    echo "Usage: $0 --remote <node-ip1> <node-ip2> ..."
    exit 1
  fi

  echo "Checking remote nodes: ${REMOTE_NODES[*]}"
  echo

  for i in "${!REMOTE_NODES[@]}"; do
    node_ip="${REMOTE_NODES[$i]}"
    node_num=$((i + 1))
    check_remote "$node_ip" "Node $node_num"
    echo
  done
else
  # Local mode: check this node
  check_local
fi

echo -e "${BLUE}=== Health Check Complete ===${NC}"
echo

# Summary
echo "Next steps:"
echo "  1. If all checks passed (✓): Proceed to connector deployment"
echo "  2. If any failed (✗): Check logs with:"
echo "     - docker ps              (check running containers)"
echo "     - docker logs <service>  (check service logs)"
echo "     - See docs/INITIALIZATION-TIMELINES.md for troubleshooting"
echo
