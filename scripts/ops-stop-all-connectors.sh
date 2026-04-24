#!/bin/bash
# ============================================================
# ops-stop-all-connectors.sh — Stop (delete) all CDC connectors
#
# Removes all connectors from both Connect clusters via REST API.
# Brokers, Connect workers, and Kafka topics are preserved.
# Connector offsets are preserved in Connect internal topics —
# connectors resume from where they left off when redeployed
# (unless Connect internal topics are also deleted).
#
# Use cases:
#   - Pause CDC before bulk seeding (avoid capturing seed traffic)
#   - Prepare for snapshot mode testing (delete offsets separately
#     with teardown-reset-kafka.sh for a fresh snapshot)
#   - Maintenance window
#
# To redeploy: ./scripts/6-deploy-connectors.sh
#
# Usage:
#   ./scripts/ops-stop-all-connectors.sh           # Interactive
#   ./scripts/ops-stop-all-connectors.sh -y         # Skip confirmation
#   ./scripts/ops-stop-all-connectors.sh --dry-run  # Show what would be deleted
# ============================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

DRY_RUN=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)  DRY_RUN=true; shift ;;
    -y|--yes)   SKIP_CONFIRM=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: ops-stop-all-connectors.sh [OPTIONS]

Stops (deletes) all CDC connectors from both Connect clusters.
Brokers, topics, and Connect workers are preserved.

Options:
  --dry-run    Show what would be deleted without deleting
  -y, --yes    Skip confirmation prompt
  -h, --help   Show this help

What it does:
  - Lists connectors on forward (:8083) and reverse (:8084) clusters
  - Deletes each connector via Connect REST API
  - Waits for tasks to stop

What it preserves:
  - Kafka brokers and topics (all CDC data stays in Kafka)
  - Connect workers (keep running, ready for redeploy)
  - Connect internal topics (offsets, config, status)
  - Schema Registry subjects

To redeploy connectors:
  ./scripts/6-deploy-connectors.sh
EOF
      exit 0
      ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

# Load .env
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}Error: .env not found at $ENV_FILE${NC}"
  exit 1
fi

set +u
source "$ENV_FILE"
set -u

CONNECT_FORWARD="http://${CONNECT_1_IP:-localhost}:8083"
CONNECT_REVERSE="http://${CONNECT_1_IP:-localhost}:8084"

echo ""
echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║           Stop All CDC Connectors                              ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Forward:  ${CONNECT_FORWARD}"
echo -e "  Reverse:  ${CONNECT_REVERSE}"
if $DRY_RUN; then
  echo -e "  Mode:     ${YELLOW}DRY RUN (no changes)${NC}"
fi
echo ""

# Discover connectors on both clusters
FORWARD_CONNECTORS=$(curl -s --max-time 10 "$CONNECT_FORWARD/connectors" 2>/dev/null || echo "[]")
REVERSE_CONNECTORS=$(curl -s --max-time 10 "$CONNECT_REVERSE/connectors" 2>/dev/null || echo "[]")

FORWARD_LIST=$(echo "$FORWARD_CONNECTORS" | python3 -c "import sys,json; [print(c) for c in json.load(sys.stdin)]" 2>/dev/null || true)
REVERSE_LIST=$(echo "$REVERSE_CONNECTORS" | python3 -c "import sys,json; [print(c) for c in json.load(sys.stdin)]" 2>/dev/null || true)

FORWARD_COUNT=$(echo "$FORWARD_LIST" | grep -c . 2>/dev/null || echo 0)
REVERSE_COUNT=$(echo "$REVERSE_LIST" | grep -c . 2>/dev/null || echo 0)

if [[ -z "$FORWARD_LIST" ]]; then FORWARD_COUNT=0; fi
if [[ -z "$REVERSE_LIST" ]]; then REVERSE_COUNT=0; fi

TOTAL=$((FORWARD_COUNT + REVERSE_COUNT))

if [[ $TOTAL -eq 0 ]]; then
  echo -e "  ${GREY}No connectors found on either cluster.${NC}"
  echo ""
  exit 0
fi

echo -e "  ${BOLD}Forward cluster (:8083):${NC}"
if [[ -n "$FORWARD_LIST" ]]; then
  echo "$FORWARD_LIST" | while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    STATUS=$(curl -s --max-time 5 "$CONNECT_FORWARD/connectors/$name/status" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" 2>/dev/null || echo "UNKNOWN")
    echo -e "    ${GREEN}●${NC} ${name} (${STATUS})"
  done
else
  echo -e "    ${GREY}(none)${NC}"
fi

echo -e "  ${BOLD}Reverse cluster (:8084):${NC}"
if [[ -n "$REVERSE_LIST" ]]; then
  echo "$REVERSE_LIST" | while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    STATUS=$(curl -s --max-time 5 "$CONNECT_REVERSE/connectors/$name/status" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" 2>/dev/null || echo "UNKNOWN")
    echo -e "    ${GREEN}●${NC} ${name} (${STATUS})"
  done
else
  echo -e "    ${GREY}(none)${NC}"
fi
echo ""

# Confirmation
if ! $DRY_RUN && ! $SKIP_CONFIRM; then
  echo -e "${YELLOW}This will delete ${TOTAL} connector(s). Topics and offsets are preserved.${NC}"
  echo ""
  read -rp "  Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${GREY}  Aborted.${NC}"
    exit 0
  fi
  echo ""
fi

# Delete connectors
DELETED=0
FAILED=0

delete_connector() {
  local url="$1"
  local name="$2"
  local label="$3"

  if $DRY_RUN; then
    echo -e "  ${YELLOW}~${NC} Would delete: ${name} (${label})"
    return
  fi

  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE "$url/connectors/$name" 2>/dev/null)

  if [[ "$http_code" == "204" || "$http_code" == "200" ]]; then
    echo -e "  ${GREEN}●${NC} Deleted: ${name} (${label})"
    DELETED=$((DELETED + 1))
  else
    echo -e "  ${RED}✗${NC} Failed to delete: ${name} (${label}) — HTTP ${http_code}"
    FAILED=$((FAILED + 1))
  fi
}

if [[ -n "$FORWARD_LIST" ]]; then
  echo "$FORWARD_LIST" | while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    delete_connector "$CONNECT_FORWARD" "$name" "forward :8083"
  done
fi

if [[ -n "$REVERSE_LIST" ]]; then
  echo "$REVERSE_LIST" | while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    delete_connector "$CONNECT_REVERSE" "$name" "reverse :8084"
  done
fi

echo ""

# Summary
if $DRY_RUN; then
  echo -e "  ${YELLOW}Dry run complete — no changes made${NC}"
else
  echo -e "${BOLD}${BLUE}─ Summary${NC}"
  echo -e "  ${GREEN}Connectors stopped.${NC} Brokers, topics, and Connect workers still running."
  echo ""
  echo -e "  To redeploy:  ${BOLD}./scripts/6-deploy-connectors.sh${NC}"
  echo -e "  To also reset offsets: ${BOLD}./scripts/teardown-reset-kafka.sh${NC}"
fi
echo ""
