#!/bin/bash
# ============================================================
# ops-stop-connect-workers.sh — Force-stop Connect workers only
#
# Stops connect-1 and connect-2 containers on Node 4 while
# keeping Schema Registry, node-exporter, and cAdvisor running.
#
# Tries graceful compose stop first. If containers survive,
# falls back to docker stop (10s timeout).
#
# Use cases:
#   - Pre-requisite before deleting Connect internal topics
#   - Stuck connector tasks that won't respond to REST API
#   - Connect worker restart without full node cycle
#
# To restart workers:
#   ./scripts/ops-start-connect-workers.sh
#   — or —
#   ./scripts/5-start-node.sh connect  (restarts all Node 4 services)
#
# Usage (from jumpbox — dispatches via SSM):
#   ./scripts/ops-stop-connect-workers.sh           # Interactive
#   ./scripts/ops-stop-connect-workers.sh -y         # Skip confirmation
#   ./scripts/ops-stop-connect-workers.sh --force    # Skip compose stop, go straight to docker stop
#   ./scripts/ops-stop-connect-workers.sh --local    # Run directly on Node 4
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

LOCAL_MODE=0
SKIP_CONFIRM=false
FORCE_STOP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --local)   LOCAL_MODE=1; shift ;;
    --force)   FORCE_STOP=true; shift ;;
    -y|--yes)  SKIP_CONFIRM=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ops-stop-connect-workers.sh [OPTIONS]

Force-stop Connect workers (connect-1, connect-2) on Node 4.
Schema Registry and other services are preserved.

Options:
  --local    Run directly on Node 4 (skip SSM dispatch)
  --force    Skip graceful compose stop, go straight to docker stop
  -y, --yes  Skip confirmation prompt
  -h, --help Show this help

What it stops:
  - connect-1 (forward CDC, port 8083)
  - connect-2 (reverse CDC, port 8084)

What it preserves:
  - Schema Registry
  - Kafka brokers
  - All topics and consumer groups
  - node-exporter, cAdvisor

To restart:
  ./scripts/5-start-node.sh connect
EOF
      exit 0
      ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}Error: .env not found at $ENV_FILE${NC}"
  exit 1
fi

set +u
source "$ENV_FILE"
set -u

# ── SSM Dispatch ──────────────────────────────────────────────────────────

if [[ "$LOCAL_MODE" -eq 0 && "${CDC_ON_NODE:-}" != "1" ]]; then
  AWS_REGION="${AWS_REGION:-us-east-1}"
  INSTANCE_ID="${CONNECT_1_INSTANCE_ID:-}"
  DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
  DEPLOY_DIR="/home/${DEPLOY_USER}/cdc-on-ec2-docker"

  if [[ -z "$INSTANCE_ID" ]]; then
    echo -e "${RED}Error: CONNECT_1_INSTANCE_ID not set in .env${NC}"
    exit 1
  fi

  echo ""
  echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║           Force-Stop Connect Workers                           ║${NC}"
  echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "  Target:  Node 4 (${CONNECT_1_IP}) — ${INSTANCE_ID}"
  echo ""

  if ! $SKIP_CONFIRM; then
    echo -e "${YELLOW}This will stop connect-1 and connect-2. Schema Registry is preserved.${NC}"
    echo ""
    read -rp "  Continue? [y/N] " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      echo -e "${GREY}  Aborted.${NC}"
      exit 0
    fi
    echo ""
  fi

  COMPOSE_CMD="cd ${DEPLOY_DIR} && docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml"

  ssm_run() {
    local remote_cmd="$1"
    local cmd_id
    cmd_id=$(aws ssm send-command \
      --region "$AWS_REGION" \
      --instance-ids "$INSTANCE_ID" \
      --document-name "AWS-RunShellScript" \
      --parameters "$(printf '{"commands":["%s"],"executionTimeout":["120"]}' "$remote_cmd")" \
      --timeout-seconds 120 \
      --output text \
      --query 'Command.CommandId' 2>/dev/null)

    if [[ -z "$cmd_id" ]]; then
      echo ""
      return 1
    fi

    for i in $(seq 1 24); do
      local s
      s=$(aws ssm get-command-invocation \
        --region "$AWS_REGION" \
        --command-id "$cmd_id" \
        --instance-id "$INSTANCE_ID" \
        --query 'Status' --output text 2>/dev/null || echo "Pending")
      if [[ "$s" == "Success" ]]; then
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$cmd_id" \
          --instance-id "$INSTANCE_ID" \
          --query 'StandardOutputContent' --output text 2>/dev/null
        return 0
      elif [[ "$s" == "Failed" || "$s" == "TimedOut" || "$s" == "Cancelled" ]]; then
        aws ssm get-command-invocation \
          --region "$AWS_REGION" \
          --command-id "$cmd_id" \
          --instance-id "$INSTANCE_ID" \
          --query 'StandardErrorContent' --output text 2>/dev/null | tail -5
        return 1
      fi
      sleep 5
    done
    return 1
  }

  # Check how many connect containers are running
  BEFORE=$(ssm_run "docker ps -q -f name=connect -f status=running | wc -l" 2>/dev/null | tr -d '[:space:]')
  if [[ "${BEFORE:-0}" -eq 0 ]]; then
    echo -e "  ${GREY}○${NC} No Connect workers running on Node 4"
    echo ""
    exit 0
  fi
  echo -e "  ${GREY}Found ${BEFORE} running Connect container(s)${NC}"

  # Step 1: Graceful compose stop (unless --force)
  if ! $FORCE_STOP; then
    echo -e "  ${GREY}Attempting graceful compose stop...${NC}"
    ssm_run "${COMPOSE_CMD} stop connect-1 connect-2" >/dev/null 2>&1
    sleep 3

    STILL=$(ssm_run "docker ps -q -f name=connect -f status=running | wc -l" 2>/dev/null | tr -d '[:space:]')
    if [[ "${STILL:-0}" -eq 0 ]]; then
      echo -e "  ${GREEN}●${NC} Connect workers stopped (graceful)"
      echo ""
      exit 0
    fi
    echo -e "  ${YELLOW}⚠${NC} ${STILL} container(s) still running after compose stop"
  fi

  # Step 2: Force docker stop
  echo -e "  ${GREY}Forcing docker stop (10s timeout)...${NC}"
  ssm_run "docker ps -q -f name=connect -f status=running | xargs -r docker stop -t 10" >/dev/null 2>&1
  sleep 3

  FINAL=$(ssm_run "docker ps -q -f name=connect -f status=running | wc -l" 2>/dev/null | tr -d '[:space:]')
  if [[ "${FINAL:-0}" -eq 0 ]]; then
    echo -e "  ${GREEN}●${NC} Connect workers stopped (forced)"
  else
    echo -e "  ${RED}✗${NC} ${FINAL} container(s) still running — may need manual intervention"
    echo -e "  ${GREY}Try: aws ssm start-session --target ${INSTANCE_ID}${NC}"
    echo -e "  ${GREY}Then: docker kill \$(docker ps -q -f name=connect)${NC}"
    exit 1
  fi
  echo ""
  exit 0
fi

# ── On-Node Execution ─────────────────────────────────────────────────────

cd "$REPO_DIR" || exit 1

echo ""
echo -e "${BOLD}${BLUE}─ Stop Connect Workers${NC}"

COMPOSE_CMD="docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml"

check_running() {
  docker ps -q -f name=connect -f status=running 2>/dev/null | head -2
}

BEFORE=$(check_running | wc -l | tr -d ' ')
if [[ "$BEFORE" -eq 0 ]]; then
  echo -e "  ${GREY}○${NC} No Connect workers running"
  echo ""
  exit 0
fi
echo -e "  ${GREY}Found ${BEFORE} running Connect container(s)${NC}"

# Step 1: Graceful compose stop (unless --force)
if ! $FORCE_STOP; then
  echo -e "  ${GREY}Attempting graceful compose stop...${NC}"
  $COMPOSE_CMD stop connect-1 connect-2 2>/dev/null || true
  sleep 5

  STILL=$(check_running | wc -l | tr -d ' ')
  if [[ "$STILL" -eq 0 ]]; then
    echo -e "  ${GREEN}●${NC} Connect workers stopped (graceful)"
    echo ""
    exit 0
  fi
  echo -e "  ${YELLOW}⚠${NC} ${STILL} container(s) still running after compose stop"
fi

# Step 2: Force docker stop
echo -e "  ${GREY}Forcing docker stop (10s timeout)...${NC}"
check_running | xargs -r docker stop -t 10 2>/dev/null || true
sleep 3

FINAL=$(check_running | wc -l | tr -d ' ')
if [[ "$FINAL" -eq 0 ]]; then
  echo -e "  ${GREEN}●${NC} Connect workers stopped (forced)"
else
  echo -e "  ${RED}✗${NC} ${FINAL} container(s) still running — may need manual intervention"
  echo -e "  ${GREY}Try: docker kill \$(docker ps -q -f name=connect)${NC}"
  exit 1
fi
echo ""
