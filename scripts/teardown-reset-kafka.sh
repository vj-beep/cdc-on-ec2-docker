#!/usr/bin/env bash
###############################################################################
# teardown-reset-kafka.sh — Clean Kafka topics, consumer groups, and SR subjects
#
# Resets all CDC state from Kafka while keeping brokers running.
#
# Order of operations (per Confluent best practices):
#   1. Delete all connectors from both Connect clusters
#   2. Stop Connect workers (required before deleting Connect internal topics)
#   3. Delete CDC topics (sqlserver.*, aurora.*)
#   4. Delete DLQ topics (dlq-*), schema history (_schema-history-*)
#   5. Delete Connect internal topics (connect-forward-*, connect-reverse-*)
#   6. Delete consumer groups (CDC connectors + Connect cluster groups)
#   7. Delete Schema Registry subjects (via REST API — _schemas topic preserved)
#   8. Restart Connect workers (recreates internal topics automatically)
#
# After running this, redeploy connectors with:
#   ./scripts/6-deploy-connectors.sh
#
# Runs from the jumpbox — dispatches commands to broker/connect nodes
# via SSH (DISPATCH_MODE=ssh) or SSM (DISPATCH_MODE=ssm).
#
# Usage:
#   ./scripts/teardown-reset-kafka.sh           # Interactive (confirms first)
#   ./scripts/teardown-reset-kafka.sh -y        # Skip confirmation
#   ./scripts/teardown-reset-kafka.sh --dry-run # Show what would be deleted
#
# Preserves:
#   - Broker processes (KRaft, Docker containers)
#   - __consumer_offsets (compacted — stale entries auto-expire)
#   - _schemas (SR internal — subjects deleted via REST API, topic stays)
#   - _confluent-metrics, _confluent-controlcenter-* (Control Center)
#
# WARNING: This is DESTRUCTIVE — all CDC messages, offsets, and schemas are lost.
###############################################################################

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo -e "${RED}Error: .env not found at $ENV_FILE${NC}"
  exit 1
fi

set +u
source "$ENV_FILE"
set -u

DRY_RUN=false
SKIP_CONFIRM=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)  DRY_RUN=true; shift ;;
    -y|--yes)   SKIP_CONFIRM=true; shift ;;
    -h|--help)
      cat <<'EOF'
Usage: teardown-reset-kafka.sh [OPTIONS]

Resets all CDC state from Kafka while keeping brokers running.

Options:
  --dry-run    Show what would be deleted without deleting
  -y, --yes    Skip confirmation prompt
  -h, --help   Show this help

What it deletes:
  - All connectors (both Connect clusters)
  - CDC topics: sqlserver.*, aurora.*
  - Schema history: _schema-history-*
  - DLQ topics: dlq-*
  - Connect internal topics: connect-forward-*, connect-reverse-*
  - Consumer groups: connect-jdbc-sink-*, connect-debezium-*, connect-forward, connect-reverse
  - Schema Registry subjects (all, via REST API)

What it preserves:
  - Broker processes and Docker containers
  - __consumer_offsets (compacted, stale entries auto-expire)
  - _schemas (SR internal topic — subjects deleted via API)
  - _confluent-metrics, _confluent-controlcenter-* (Control Center)

Order of operations:
  1. Delete connectors (REST API)
  2. Stop Connect workers (required before deleting internal topics)
  3. Delete topics (kafka-topics --delete)
  4. Delete consumer groups (kafka-consumer-groups --delete)
  5. Delete Schema Registry subjects (REST API)
  6. Restart Connect workers (recreates internal topics)

After reset:
  ./scripts/6-deploy-connectors.sh    # redeploy connectors
  ./scripts/7-validate-deployment.sh         # validate
EOF
      exit 0
      ;;
    *) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

BOOTSTRAP="${BROKER_1_IP:-localhost}:9092"
DISPATCH_MODE="${DISPATCH_MODE:-ssh}"
CONNECT_FORWARD="http://${CONNECT_1_IP:-localhost}:8083"
CONNECT_REVERSE="http://${CONNECT_1_IP:-localhost}:8084"
SR_URL="http://${CONNECT_1_IP:-localhost}:${SCHEMA_REGISTRY_PORT:-8081}"

# ── Helpers ────────────────────────────────────────────────────────────────

run_on_broker() {
  local cmd="$1"
  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    ssh -n -q -o StrictHostKeyChecking=no -i "${SSH_KEY_PATH:-~/.ssh/id_rsa}" \
      "${DEPLOY_USER:-ec2-user}@${BROKER_1_IP}" \
      "docker exec \$(docker ps -q -f name=broker --no-trunc | head -1) $cmd" 2>&1
  else
    local instance_id="${BROKER_1_INSTANCE_ID}"
    local cmd_id
    cmd_id=$(aws ssm send-command \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --parameters "{\"commands\":[\"docker exec \$(docker ps -q -f name=broker --no-trunc | head -1) $cmd\"]}" \
      --query "Command.CommandId" --output text 2>&1)
    sleep 3
    aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --query "StandardOutputContent" --output text 2>&1
  fi
}

run_on_connect() {
  local cmd="$1"
  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    ssh -n -q -o StrictHostKeyChecking=no -i "${SSH_KEY_PATH:-~/.ssh/id_rsa}" \
      "${DEPLOY_USER:-ec2-user}@${CONNECT_1_IP}" "$cmd" 2>&1
  else
    local instance_id="${CONNECT_1_INSTANCE_ID}"
    local cmd_id
    cmd_id=$(aws ssm send-command \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --parameters "{\"commands\":[\"$cmd\"]}" \
      --query "Command.CommandId" --output text 2>&1)
    sleep 5
    aws ssm get-command-invocation \
      --command-id "$cmd_id" \
      --instance-id "$instance_id" \
      --query "StandardOutputContent" --output text 2>&1
  fi
}

echo ""
echo -e "${BOLD}${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║           Kafka State Reset                                   ║${NC}"
echo -e "${BOLD}${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Bootstrap:  ${BOOTSTRAP}"
echo -e "  Dispatch:   ${DISPATCH_MODE}"
echo -e "  Forward:    ${CONNECT_FORWARD}"
echo -e "  Reverse:    ${CONNECT_REVERSE}"
echo -e "  SR:         ${SR_URL}"
if $DRY_RUN; then
  echo -e "  Mode:       ${YELLOW}DRY RUN (no changes)${NC}"
fi
echo ""

# ── Confirmation ───────────────────────────────────────────────────────────

if ! $DRY_RUN && ! $SKIP_CONFIRM; then
  echo -e "${YELLOW}WARNING: This will delete all CDC topics, connectors, consumer groups,${NC}"
  echo -e "${YELLOW}         Schema Registry subjects, and Connect internal state.${NC}"
  echo -e "${YELLOW}         Connect workers will be stopped and restarted.${NC}"
  echo ""
  read -rp "  Continue? [y/N] " confirm
  if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${GREY}Aborted.${NC}"
    exit 0
  fi
  echo ""
fi

# ── Step 1: Delete connectors ─────────────────────────────────────────────

echo -e "${BOLD}${BLUE}─ Step 1/6: Delete Connectors${NC}"

delete_connectors() {
  local url="$1"
  local label="$2"
  local connectors
  connectors=$(curl -s --max-time 10 "$url/connectors" 2>/dev/null || echo "[]")

  if [[ "$connectors" == "[]" || -z "$connectors" ]]; then
    echo -e "  ${GREY}○${NC} ${label}: no connectors"
    return
  fi

  for name in $(echo "$connectors" | python3 -c "import sys,json; [print(c) for c in json.load(sys.stdin)]" 2>/dev/null); do
    if $DRY_RUN; then
      echo -e "  ${YELLOW}~${NC} Would delete connector: ${name} (${label})"
    else
      curl -s -X DELETE "$url/connectors/$name" >/dev/null 2>&1
      echo -e "  ${GREEN}●${NC} Deleted connector: ${name} (${label})"
    fi
  done
}

delete_connectors "$CONNECT_FORWARD" "forward :8083"
delete_connectors "$CONNECT_REVERSE" "reverse :8084"

if ! $DRY_RUN; then
  echo -e "  ${GREY}Waiting 5s for connectors to stop...${NC}"
  sleep 5
fi
echo ""

# ── Step 2: Stop Connect workers ──────────────────────────────────────────

echo -e "${BOLD}${BLUE}─ Step 2/6: Stop Connect Workers${NC}"
echo -e "  ${GREY}Connect internal topics must not be deleted while workers are running${NC}"

DEPLOY_DIR="${DEPLOY_DIR:-/home/${DEPLOY_USER:-ec2-user}/cdc-on-ec2-docker}"

if $DRY_RUN; then
  echo -e "  ${YELLOW}~${NC} Would stop connect-1 and connect-2 on ${CONNECT_1_IP}"
else
  run_on_connect "cd ${DEPLOY_DIR} && docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml stop connect-1 connect-2" >/dev/null 2>&1
  sleep 5

  RUNNING_CONNECT=$(run_on_connect "docker ps -q -f name=connect -f status=running" 2>/dev/null | tr -d '\r' | xargs)
  if [[ -n "$RUNNING_CONNECT" ]]; then
    echo -e "  ${YELLOW}⚠${NC} Connect containers still running after compose stop — forcing docker stop"
    run_on_connect "docker ps -q -f name=connect -f status=running | xargs -r docker stop -t 10" >/dev/null 2>&1
    sleep 5
    STILL_RUNNING=$(run_on_connect "docker ps -q -f name=connect -f status=running" 2>/dev/null | tr -d '\r' | xargs)
    if [[ -n "$STILL_RUNNING" ]]; then
      echo -e "  ${RED}✗${NC} Connect workers could not be stopped — internal topic deletion may fail"
    else
      echo -e "  ${GREEN}●${NC} Connect workers force-stopped"
    fi
  else
    echo -e "  ${GREEN}●${NC} Connect workers stopped"
  fi
fi
echo ""

# ── Step 3: Delete topics ─────────────────────────────────────────────────

echo -e "${BOLD}${BLUE}─ Step 3/6: Delete Topics${NC}"

ALL_TOPICS=$(run_on_broker "kafka-topics --bootstrap-server ${BOOTSTRAP} --list" 2>/dev/null | tr -d '\r' || echo "")

CDC_TOPICS=$(echo "$ALL_TOPICS" | grep -E "^(sqlserver\.|aurora\.|_schema-history-|dlq-|connect-forward-|connect-reverse-)" | sed 's/[[:space:]]*$//' | sort || true)

if [[ -z "$CDC_TOPICS" ]]; then
  echo -e "  ${GREY}○${NC} No CDC topics found"
else
  TOPIC_COUNT=$(echo "$CDC_TOPICS" | wc -l | tr -d ' ')
  echo -e "  Found ${TOPIC_COUNT} CDC-related topics:"
  echo ""

  while IFS= read -r topic; do
    topic=$(echo "$topic" | tr -d '\r' | xargs)
    [[ -z "$topic" ]] && continue
    if $DRY_RUN; then
      echo -e "  ${YELLOW}~${NC} Would delete: ${topic}"
    else
      run_on_broker "kafka-topics --bootstrap-server ${BOOTSTRAP} --delete --topic ${topic}" >/dev/null 2>&1
      echo -e "  ${GREEN}●${NC} Deleted: ${topic}"
    fi
  done <<< "$CDC_TOPICS"

  if ! $DRY_RUN; then
    echo ""
    echo -e "  ${GREY}Waiting for topic deletions to propagate...${NC}"
    for attempt in $(seq 1 15); do
      REMAINING=$(run_on_broker "kafka-topics --bootstrap-server ${BOOTSTRAP} --list" 2>/dev/null \
        | grep -E "^(sqlserver\.|aurora\.|_schema-history-|dlq-|connect-forward-|connect-reverse-)" || true)
      if [[ -z "$REMAINING" ]]; then
        echo -e "  ${GREEN}●${NC} All CDC topics deleted (${attempt}s)"
        break
      fi
      if [[ $attempt -eq 15 ]]; then
        echo -e "  ${YELLOW}⚠${NC} Some topics still pending deletion after 15s:"
        echo "$REMAINING" | while IFS= read -r t; do echo -e "      $t"; done
      fi
      sleep 1
    done
  fi
fi
echo ""

# ── Step 4: Delete consumer groups ────────────────────────────────────────

echo -e "${BOLD}${BLUE}─ Step 4/6: Delete Consumer Groups${NC}"

ALL_GROUPS=$(run_on_broker "kafka-consumer-groups --bootstrap-server ${BOOTSTRAP} --list" 2>/dev/null | tr -d '\r' || echo "")

CDC_GROUPS=$(echo "$ALL_GROUPS" | grep -E "^connect-(jdbc-sink|debezium|forward|reverse)" | sort || true)

if [[ -z "$CDC_GROUPS" ]]; then
  echo -e "  ${GREY}○${NC} No CDC consumer groups found"
else
  while IFS= read -r group; do
    [[ -z "$group" ]] && continue
    if $DRY_RUN; then
      echo -e "  ${YELLOW}~${NC} Would delete: ${group}"
    else
      run_on_broker "kafka-consumer-groups --bootstrap-server ${BOOTSTRAP} --delete --group ${group}" >/dev/null 2>&1
      echo -e "  ${GREEN}●${NC} Deleted: ${group}"
    fi
  done <<< "$CDC_GROUPS"
fi
echo ""

# ── Step 5: Delete Schema Registry subjects ───────────────────────────────

echo -e "${BOLD}${BLUE}─ Step 5/6: Delete Schema Registry Subjects${NC}"

SUBJECTS=$(curl -s --max-time 10 "$SR_URL/subjects" 2>/dev/null || echo "[]")

if [[ "$SUBJECTS" == "[]" || -z "$SUBJECTS" ]]; then
  echo -e "  ${GREY}○${NC} No subjects found"
else
  SUBJECT_COUNT=$(echo "$SUBJECTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null || echo "0")
  echo -e "  Found ${SUBJECT_COUNT} subjects"

  for subject in $(echo "$SUBJECTS" | python3 -c "import sys,json; [print(s) for s in json.load(sys.stdin)]" 2>/dev/null); do
    if $DRY_RUN; then
      echo -e "  ${YELLOW}~${NC} Would delete: ${subject}"
    else
      curl -s -X DELETE "$SR_URL/subjects/$subject" >/dev/null 2>&1
      curl -s -X DELETE "$SR_URL/subjects/$subject?permanent=true" >/dev/null 2>&1
      echo -e "  ${GREEN}●${NC} Deleted: ${subject}"
    fi
  done
fi
echo ""

# ── Step 6: Restart Connect workers ───────────────────────────────────────

echo -e "${BOLD}${BLUE}─ Step 6/6: Restart Connect Workers${NC}"
echo -e "  ${GREY}Connect recreates internal topics (offsets, config, status) on startup${NC}"

if $DRY_RUN; then
  echo -e "  ${YELLOW}~${NC} Would restart connect-1 and connect-2 on ${CONNECT_1_IP}"
else
  run_on_connect "cd ${DEPLOY_DIR} && bash monitoring/jmx-exporter/download-jmx-agent.sh >/dev/null 2>&1 && docker compose -f docker-compose.yml -f docker-compose.connect-schema-registry.yml start connect-1 connect-2" >/dev/null 2>&1
  echo -e "  ${GREEN}●${NC} Connect workers starting"

  echo -e "  ${GREY}Waiting for Connect REST API (up to 150s)...${NC}"
  for i in $(seq 1 75); do
    if curl -s --max-time 3 "$CONNECT_FORWARD/connectors" >/dev/null 2>&1 && \
       curl -s --max-time 3 "$CONNECT_REVERSE/connectors" >/dev/null 2>&1; then
      echo -e "  ${GREEN}●${NC} Connect REST APIs ready ($((i * 2))s)"
      break
    fi
    sleep 2
  done

  if ! curl -s --max-time 3 "$CONNECT_FORWARD/connectors" >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${NC} Connect forward (:8083) not ready yet — may need more time"
  fi
  if ! curl -s --max-time 3 "$CONNECT_REVERSE/connectors" >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${NC} Connect reverse (:8084) not ready yet — may need more time"
  fi
fi
echo ""

# ── Summary ───────────────────────────────────────────────────────────────

echo -e "${BOLD}${BLUE}─ Summary${NC}"
if $DRY_RUN; then
  echo -e "  ${YELLOW}Dry run complete — no changes made${NC}"
  echo -e "  Run without --dry-run to apply"
else
  echo -e "  ${GREEN}Kafka state reset complete${NC}"
  echo ""
  echo -e "  Brokers running, Connect workers restarted, topics/groups/subjects cleaned."
  echo -e "  Next steps:"
  echo -e "    1. ${BOLD}./scripts/6-deploy-connectors.sh${NC}  — redeploy connectors"
  echo -e "    2. ${BOLD}./scripts/7-validate-deployment.sh${NC}       — validate infrastructure"
fi
echo ""
