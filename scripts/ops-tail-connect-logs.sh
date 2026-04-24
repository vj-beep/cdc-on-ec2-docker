#!/bin/bash
# ============================================================
# ops-tail-connect-logs.sh — Tail connect-1 (forward) or connect-2 (reverse) logs
#
# Opens an interactive SSM session to Node 4 and streams docker logs.
# Ctrl+C exits the tail; close the session window to disconnect.
#
# Usage (from jumpbox):
#   ./scripts/ops-tail-connect-logs.sh             # Interactive menu
#   ./scripts/ops-tail-connect-logs.sh forward     # Forward path (connect-1, :8083)
#   ./scripts/ops-tail-connect-logs.sh reverse     # Reverse path (connect-2, :8084)
#   ./scripts/ops-tail-connect-logs.sh --local [forward|reverse]  # Run directly on Node 4
#
# Options:
#   forward|reverse    Which connect worker to tail
#   --tail N           Number of historical lines to show on start (default: 50)
#   --local            Run directly on Node 4 (skip SSM dispatch)
#   -h, --help         Show this help
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
TAIL_LINES=50
DIRECTION=""

while [[ $# -gt 0 ]]; do
  case $1 in
    forward|reverse) DIRECTION=$1; shift ;;
    --local)         LOCAL_MODE=1; shift ;;
    --tail)          TAIL_LINES=$2; shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: ops-tail-connect-logs.sh [forward|reverse] [OPTIONS]

Tail logs for connect-1 (forward CDC) or connect-2 (reverse CDC) on Node 4.

Arguments:
  forward    connect-1 — SQL Server → Aurora (port 8083)
  reverse    connect-2 — Aurora → SQL Server (port 8084)

Options:
  --tail N   Show last N lines on start (default: 50)
  --local    Run directly on Node 4 (skip SSM dispatch)
  -h, --help Show this help

Examples:
  ./scripts/ops-tail-connect-logs.sh              # Interactive menu
  ./scripts/ops-tail-connect-logs.sh forward      # Tail forward path
  ./scripts/ops-tail-connect-logs.sh reverse --tail 200
  ./scripts/ops-tail-connect-logs.sh --local forward
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

# ── Direction selection ───────────────────────────────────────────────────────

if [[ -z "$DIRECTION" ]]; then
  echo ""
  echo -e "${BOLD}${BLUE}Select Connect worker to tail:${NC}"
  echo ""
  echo -e "  ${BOLD}1)${NC} forward  — connect-1  SQL Server → Aurora    (port 8083)"
  echo -e "  ${BOLD}2)${NC} reverse  — connect-2  Aurora → SQL Server     (port 8084)"
  echo ""
  read -rp "  Choice [1/2]: " choice
  case $choice in
    1|forward) DIRECTION=forward ;;
    2|reverse) DIRECTION=reverse ;;
    *) echo -e "${RED}Invalid choice.${NC}"; exit 1 ;;
  esac
  echo ""
fi

case $DIRECTION in
  forward) SERVICE="connect-1"; PORT="8083"; LABEL="SQL Server → Aurora" ;;
  reverse) SERVICE="connect-2"; PORT="8084"; LABEL="Aurora → SQL Server" ;;
  *)       echo -e "${RED}Unknown direction: $DIRECTION${NC}"; exit 1 ;;
esac
# Docker Compose prefixes containers with the project directory name
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-cdc-on-ec2-docker}"
CONTAINER="${COMPOSE_PROJECT}-${SERVICE}-1"

# ── SSM Dispatch ──────────────────────────────────────────────────────────────

if [[ "$LOCAL_MODE" -eq 0 && "${CDC_ON_NODE:-}" != "1" ]]; then
  AWS_REGION="${AWS_REGION:-us-east-1}"
  INSTANCE_ID="${CONNECT_1_INSTANCE_ID:-}"

  if [[ -z "$INSTANCE_ID" ]]; then
    echo -e "${RED}Error: CONNECT_1_INSTANCE_ID not set in .env${NC}"
    exit 1
  fi

  echo -e "${BOLD}${BLUE}Tailing: ${CONTAINER} (${LABEL})${NC}"
  echo -e "${GREY}  Node 4:    ${CONNECT_1_IP:-unknown} — ${INSTANCE_ID}${NC}"
  echo -e "${GREY}  Lines:  last ${TAIL_LINES} then live${NC}"
  echo -e "${GREY}  Exit:   Ctrl+C${NC}"
  echo ""

  # AWS-StartInteractiveCommand runs as ssm-user (not root) — sudo required for docker socket
  DOCKER_CMD="sudo docker logs -f --tail ${TAIL_LINES} ${CONTAINER}"

  exec aws ssm start-session \
    --region "$AWS_REGION" \
    --target "$INSTANCE_ID" \
    --document-name "AWS-StartInteractiveCommand" \
    --parameters "$(printf '{"command":["bash -c '"'"'%s'"'"'"]}' "$DOCKER_CMD")"
fi

# ── On-Node Execution ─────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${BLUE}Tailing: ${CONTAINER} (${LABEL})${NC}"
echo -e "${GREY}  Last ${TAIL_LINES} lines + live  |  Ctrl+C to exit${NC}"
echo ""

if ! sudo docker ps --format '{{.Names}}' | grep -q "^${CONTAINER}$"; then
  echo -e "${YELLOW}Warning: ${CONTAINER} does not appear to be running${NC}"
  echo -e "${GREY}  docker ps output:${NC}"
  sudo docker ps --format '  {{.Names}}\t{{.Status}}' | grep connect || echo "  (no connect containers)"
  echo ""
  read -rp "  Tail anyway (may show historical logs)? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    exit 0
  fi
  echo ""
fi

sudo docker logs -f --tail "$TAIL_LINES" "$CONTAINER"
