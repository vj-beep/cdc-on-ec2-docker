#!/bin/bash
###############################################################################
# Kafka Latency Audit Orchestrator
#
# Deploys and runs kafka-latency-audit.sh across all 5 CDC cluster nodes,
# collects reports, diffs configuration across nodes, and produces a
# consolidated FINDINGS.md with actionable latency recommendations.
#
# Usage:
#   bash scripts/ops-latency-audit.sh [OPTIONS]
#
# Options:
#   --audit-script PATH   Local path to kafka-latency-audit.sh (required)
#   --workdir DIR         Output directory (default: ./kafka-audit-YYYYMMDD-HHMMSS)
#   --bootstrap HOST:PORT Kafka bootstrap for active --perf probes
#   --probes              Run fio + producer-perf probes (Phase 5) — ask by default
#   --cleanup             Remove remote temp files after collection
#   --help                Show this help
#
# Dispatch modes (read from .env):
#   DISPATCH_MODE=ssm  (default) — use AWS SSM send-command (no direct SSH needed)
#   DISPATCH_MODE=ssh            — use SSH directly (SSH_KEY_PATH + node IPs)
#
# Required .env variables (SSM mode):
#   BROKER_1_INSTANCE_ID, BROKER_2_INSTANCE_ID, BROKER_3_INSTANCE_ID
#   CONNECT_1_INSTANCE_ID, MONITOR_1_INSTANCE_ID
#
# Required .env variables (SSH mode):
#   SSH_KEY_PATH, BROKER_1_IP, BROKER_2_IP, BROKER_3_IP
#   CONNECT_1_IP, MONITOR_1_IP
#
# Reference: https://developer.confluent.io/learn/kafka-performance/
###############################################################################

set -uo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GREY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Defaults ─────────────────────────────────────────────────────────────────
AUDIT_SCRIPT=""
WORKDIR="./kafka-audit-$(date +%Y%m%d-%H%M%S)"
BOOTSTRAP=""
RUN_PROBES=false
DO_CLEANUP=false
AWS_REGION_DEFAULT="us-east-1"
SSM_POLL_INTERVAL=3
SSM_MAX_WAIT=180  # seconds to wait for each SSM command

# ─── Parse args ──────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --audit-script)  AUDIT_SCRIPT="$2";  shift 2 ;;
    --workdir)       WORKDIR="$2";       shift 2 ;;
    --bootstrap)     BOOTSTRAP="$2";     shift 2 ;;
    --probes)        RUN_PROBES=true;    shift ;;
    --cleanup)       DO_CLEANUP=true;    shift ;;
    --help)
      sed -n '3,40p' "$0" | grep -E '^#' | sed 's/^# \{0,2\}//'
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# ─── Load .env ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$(cd "$SCRIPT_DIR/.." && pwd)/.env"

if [[ -f "$ENV_FILE" ]]; then
  set +u
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set -u
fi

DISPATCH_MODE="${DISPATCH_MODE:-ssm}"
DEPLOY_USER="${DEPLOY_USER:-ec2-user}"
AWS_REGION="${AWS_REGION:-$AWS_REGION_DEFAULT}"
BOOTSTRAP="${BOOTSTRAP:-${KAFKA_BOOTSTRAP_SERVERS:-}}"

# ─── Validate inputs ─────────────────────────────────────────────────────────
missing_inputs=()

if [[ -z "$AUDIT_SCRIPT" ]]; then
  missing_inputs+=("--audit-script PATH  (path to kafka-latency-audit.sh)")
fi

if [[ "${#missing_inputs[@]}" -gt 0 ]]; then
  echo -e "${RED}Missing required inputs:${NC}"
  for m in "${missing_inputs[@]}"; do
    echo "  $m"
  done
  echo ""
  echo "Example:"
  echo "  bash scripts/ops-latency-audit.sh \\"
  echo "    --audit-script ~/tools/kafka-latency-audit.sh \\"
  echo "    --bootstrap cp-node1:9092"
  exit 1
fi

if [[ ! -f "$AUDIT_SCRIPT" ]]; then
  echo -e "${RED}✗ AUDIT_SCRIPT not found: $AUDIT_SCRIPT${NC}"
  exit 1
fi

if [[ ! -s "$AUDIT_SCRIPT" ]]; then
  echo -e "${RED}✗ AUDIT_SCRIPT is empty: $AUDIT_SCRIPT${NC}"
  exit 1
fi

# ─── Build node list ──────────────────────────────────────────────────────────
# Arrays: NODE_NAMES, NODE_ADDRS (IDs for SSM, IPs for SSH), NODE_IPS (display)
declare -a NODE_NAMES NODE_ADDRS NODE_IPS NODE_LABELS

if [[ "$DISPATCH_MODE" == "ssh" ]]; then
  SSH_KEY="${SSH_KEY_PATH:-}"
  if [[ -z "$SSH_KEY" ]]; then
    echo -e "${RED}✗ SSH_KEY_PATH not set in .env (required for DISPATCH_MODE=ssh)${NC}"
    exit 1
  fi
  if [[ ! -f "$SSH_KEY" ]]; then
    echo -e "${RED}✗ SSH key not found: $SSH_KEY${NC}"
    exit 1
  fi
  NODE_NAMES=("broker1" "broker2" "broker3" "connect" "monitor")
  NODE_ADDRS=(
    "${BROKER_1_IP:-}"
    "${BROKER_2_IP:-}"
    "${BROKER_3_IP:-}"
    "${CONNECT_1_IP:-}"
    "${MONITOR_1_IP:-}"
  )
  NODE_IPS=("${NODE_ADDRS[@]}")
  NODE_LABELS=(
    "Node 1 — Broker 1"
    "Node 2 — Broker 2"
    "Node 3 — Broker 3"
    "Node 4 — Connect + Schema Registry"
    "Node 5 — Monitoring & Control"
  )
  for ip in "${NODE_ADDRS[@]}"; do
    if [[ -z "$ip" ]]; then
      echo -e "${RED}✗ One or more node IPs not set in .env (BROKER_*_IP, CONNECT_1_IP, MONITOR_1_IP)${NC}"
      exit 1
    fi
  done
else
  # SSM mode
  if ! command -v aws &>/dev/null; then
    echo -e "${RED}✗ AWS CLI not found${NC}"
    exit 1
  fi
  B1_ID="${BROKER_1_INSTANCE_ID:-}"
  B2_ID="${BROKER_2_INSTANCE_ID:-}"
  B3_ID="${BROKER_3_INSTANCE_ID:-}"
  C1_ID="${CONNECT_1_INSTANCE_ID:-}"
  M1_ID="${MONITOR_1_INSTANCE_ID:-}"
  for id_var in B1_ID B2_ID B3_ID C1_ID M1_ID; do
    val="${!id_var}"
    if [[ -z "$val" ]]; then
      echo -e "${RED}✗ Instance ID not set: $id_var (check .env)${NC}"
      exit 1
    fi
  done
  NODE_NAMES=("broker1" "broker2" "broker3" "connect" "monitor")
  NODE_ADDRS=("$B1_ID" "$B2_ID" "$B3_ID" "$C1_ID" "$M1_ID")
  NODE_IPS=(
    "${BROKER_1_IP:-}"
    "${BROKER_2_IP:-}"
    "${BROKER_3_IP:-}"
    "${CONNECT_1_IP:-}"
    "${MONITOR_1_IP:-}"
  )
  NODE_LABELS=(
    "Node 1 — Broker 1        ($B1_ID)"
    "Node 2 — Broker 2        ($B2_ID)"
    "Node 3 — Broker 3        ($B3_ID)"
    "Node 4 — Connect+SR      ($C1_ID)"
    "Node 5 — Monitoring      ($M1_ID)"
  )
fi

NODE_COUNT="${#NODE_NAMES[@]}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

log_phase() { echo -e "\n${BOLD}${BLUE}▶ $*${NC}"; }
log_ok()    { echo -e "  ${GREEN}✓${NC} $*"; }
log_warn()  { echo -e "  ${YELLOW}⚠${NC} $*"; }
log_err()   { echo -e "  ${RED}✗${NC} $*"; }
log_info()  { echo -e "  ${GREY}→${NC} $*"; }

# Run a command on a node; writes stdout+stderr to $logfile; returns exit code.
# In SSH mode: direct ssh. In SSM mode: send-command + poll.
run_remote() {
  local node_name="$1"
  local node_addr="$2"   # IP (ssh) or instance-id (ssm)
  local cmd="$3"
  local logfile="$4"
  local timeout_s="${5:-$SSM_MAX_WAIT}"

  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    ssh -n -i "$SSH_KEY" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      -o ServerAliveInterval=15 \
      "$DEPLOY_USER@$node_addr" \
      "$cmd" >"$logfile" 2>&1
    return $?
  fi

  # SSM mode
  local command_id
  command_id=$(aws ssm send-command \
    --instance-ids "$node_addr" \
    --document-name "AWS-RunShellScript" \
    --parameters "$(jq -n --arg c "$cmd" '{"commands":[$c]}')" \
    --timeout-seconds "$timeout_s" \
    --region "$AWS_REGION" \
    --query 'Command.CommandId' \
    --output text 2>>"$logfile") || true

  if [[ -z "$command_id" || "$command_id" == "None" ]]; then
    echo "SSM send-command failed for $node_name" >>"$logfile"
    return 1
  fi

  local elapsed=0
  local status=""
  while [[ $elapsed -lt $timeout_s ]]; do
    sleep "$SSM_POLL_INTERVAL"
    elapsed=$((elapsed + SSM_POLL_INTERVAL))
    local result
    result=$(aws ssm get-command-invocation \
      --command-id "$command_id" \
      --instance-id "$node_addr" \
      --region "$AWS_REGION" \
      --output json 2>/dev/null) || continue

    status=$(echo "$result" | jq -r '.Status // empty')
    case "$status" in
      Success)
        echo "$result" | jq -r '.StandardOutputContent // empty' >>"$logfile"
        echo "$result" | jq -r '.StandardErrorContent // empty'  >>"$logfile"
        return 0
        ;;
      Failed|TimedOut|Cancelled|DeliveryTimedOut|ExecutionTimedOut)
        echo "$result" | jq -r '.StandardOutputContent // empty' >>"$logfile"
        echo "$result" | jq -r '.StandardErrorContent // empty'  >>"$logfile"
        echo "SSM command status: $status" >>"$logfile"
        return 1
        ;;
    esac
  done

  echo "SSM command timed out after ${timeout_s}s (command_id=$command_id)" >>"$logfile"
  return 1
}

# SCP a local file to a remote node.
scp_to_node() {
  local node_addr="$1"
  local local_path="$2"
  local remote_path="$3"
  local logfile="$4"

  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    scp -i "$SSH_KEY" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "$local_path" "$DEPLOY_USER@$node_addr:$remote_path" \
      >>"$logfile" 2>&1
    return $?
  fi

  # SSM mode: base64-encode and write via RunShellScript
  local encoded
  encoded=$(base64 -w0 "$local_path")
  local write_cmd="echo '${encoded}' | base64 -d > ${remote_path} && chmod +x ${remote_path}"
  run_remote "scp-to" "$node_addr" "$write_cmd" "$logfile" 60
}

# SCP a remote file to a local path.
scp_from_node() {
  local node_addr="$1"
  local remote_path="$2"
  local local_path="$3"
  local logfile="$4"

  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    scp -i "$SSH_KEY" \
      -o StrictHostKeyChecking=accept-new \
      -o ConnectTimeout=10 \
      "$DEPLOY_USER@$node_addr:$remote_path" \
      "$local_path" >>"$logfile" 2>&1
    return $?
  fi

  # SSM mode: base64-encode remote file, capture, decode locally
  local fetch_log="${logfile}.b64"
  run_remote "fetch-b64" "$node_addr" "base64 -w0 '${remote_path}'" "$fetch_log" 60 || return 1
  # fetch_log now contains the base64 content (+ possible SSM noise before it)
  # The last non-empty line that looks like base64 is what we want
  grep -E '^[A-Za-z0-9+/=]+$' "$fetch_log" | tail -1 | base64 -d >"$local_path" 2>/dev/null
  [[ -s "$local_path" ]]
}

# ─── Header ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${BLUE}║         Kafka Latency Audit — 5-Node CDC Cluster             ║${NC}"
echo -e "${BOLD}${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Dispatch mode : ${BOLD}${DISPATCH_MODE^^}${NC}"
echo -e "  Audit script  : ${BOLD}$(basename "$AUDIT_SCRIPT")${NC}"
echo -e "  Output dir    : ${BOLD}$WORKDIR${NC}"
[[ -n "$BOOTSTRAP" ]] && echo -e "  Bootstrap     : ${BOLD}$BOOTSTRAP${NC}"
echo ""

# ─── Phase 1: Pre-flight ─────────────────────────────────────────────────────
log_phase "Phase 1: Pre-flight checks"

# Create output dirs
mkdir -p "$WORKDIR/raw" "$WORKDIR/diffs"
log_ok "Created output directories: $WORKDIR/{raw,diffs}"

# Verify audit script
AUDIT_LINES=$(wc -l <"$AUDIT_SCRIPT")
log_ok "Audit script verified: $AUDIT_SCRIPT ($AUDIT_LINES lines)"

# Check connectivity
declare -a REACHABLE_NAMES REACHABLE_ADDRS REACHABLE_IPS
preflight_failed=0

for i in $(seq 0 $((NODE_COUNT - 1))); do
  name="${NODE_NAMES[$i]}"
  addr="${NODE_ADDRS[$i]}"
  ip="${NODE_IPS[$i]:-}"
  label="${NODE_LABELS[$i]}"
  pf_log="$WORKDIR/raw/${name}.preflight.log"

  echo -n "  Checking $label ... "

  if [[ "$DISPATCH_MODE" == "ssh" ]]; then
    if ssh -n -i "$SSH_KEY" \
         -o ConnectTimeout=5 \
         -o StrictHostKeyChecking=accept-new \
         "$DEPLOY_USER@$addr" \
         'echo ok && sudo -n true' \
         >"$pf_log" 2>&1; then
      echo -e "${GREEN}reachable${NC}"
      REACHABLE_NAMES+=("$name")
      REACHABLE_ADDRS+=("$addr")
      REACHABLE_IPS+=("$ip")
    else
      echo -e "${RED}FAILED${NC} (see $pf_log)"
      preflight_failed=$((preflight_failed + 1))
    fi
  else
    # SSM connectivity: send a trivial echo
    if run_remote "$name" "$addr" "echo ok && sudo -n true" "$pf_log" 30; then
      echo -e "${GREEN}reachable${NC}"
      REACHABLE_NAMES+=("$name")
      REACHABLE_ADDRS+=("$addr")
      REACHABLE_IPS+=("$ip")
    else
      echo -e "${RED}FAILED${NC} (see $pf_log)"
      preflight_failed=$((preflight_failed + 1))
    fi
  fi
done

REACHABLE_COUNT="${#REACHABLE_NAMES[@]}"
echo ""
if [[ $REACHABLE_COUNT -eq 0 ]]; then
  log_err "No nodes reachable. Aborting."
  exit 1
fi
if [[ $preflight_failed -gt 0 ]]; then
  log_warn "$preflight_failed node(s) unreachable — continuing with $REACHABLE_COUNT reachable node(s)."
else
  log_ok "All $REACHABLE_COUNT nodes reachable."
fi

# ─── Phase 2: Deploy + run audit (parallel) ───────────────────────────────────
log_phase "Phase 2: Deploy and run audit (parallel, read-only)"

declare -a AUDIT_PIDS AUDIT_LOGS REPORT_FILES

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  name="${REACHABLE_NAMES[$i]}"
  addr="${REACHABLE_ADDRS[$i]}"
  node_log="$WORKDIR/raw/${name}.log"
  AUDIT_LOGS+=("$node_log")
  report_placeholder="$WORKDIR/raw/${name}-audit.txt"
  REPORT_FILES+=("$report_placeholder")

  (
    # Step 1: copy script
    if ! scp_to_node "$addr" "$AUDIT_SCRIPT" "/tmp/kafka-latency-audit.sh" "$node_log"; then
      echo "PHASE2_ERROR: scp failed" >>"$node_log"
      exit 1
    fi

    # Step 2: run audit (no --fio, no --perf)
    if ! run_remote "$name" "$addr" \
        "sudo bash /tmp/kafka-latency-audit.sh 2>&1" \
        "$node_log" 120; then
      echo "PHASE2_ERROR: audit run failed" >>"$node_log"
      exit 1
    fi

    # Step 3: pull report file back
    # The audit script writes /tmp/kafka-latency-audit-<timestamp>.txt
    fetch_log="$node_log.list"
    if ! run_remote "$name" "$addr" \
        "ls /tmp/kafka-latency-audit-*.txt 2>/dev/null | sort | tail -1" \
        "$fetch_log" 20; then
      echo "PHASE2_ERROR: ls failed" >>"$node_log"
      exit 1
    fi
    remote_report=$(grep '/tmp/kafka-latency-audit-' "$fetch_log" | tail -1 | tr -d '[:space:]')
    if [[ -z "$remote_report" ]]; then
      # Report content was written to stdout (captured in node_log) — extract it
      # Copy stdout capture as the report
      cp "$node_log" "$report_placeholder"
    else
      scp_from_node "$addr" "$remote_report" "$report_placeholder" "$node_log" || \
        cp "$node_log" "$report_placeholder"
    fi
  ) &
  AUDIT_PIDS+=($!)
done

# Wait for all parallel jobs
all_ok=true
for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  name="${REACHABLE_NAMES[$i]}"
  pid="${AUDIT_PIDS[$i]}"
  if wait "$pid"; then
    log_ok "$name: audit complete → ${REPORT_FILES[$i]}"
  else
    log_warn "$name: audit encountered errors (see ${AUDIT_LOGS[$i]})"
    all_ok=false
  fi
done

$all_ok && log_ok "Phase 2 complete." || log_warn "Phase 2 complete with warnings."

# ─── Phase 3: Cross-node diff ─────────────────────────────────────────────────
log_phase "Phase 3: Cross-node configuration diff"

# Sections to extract and compare (match section headers in the audit script output)
SECTIONS=(
  "SYSTEM OVERVIEW"
  "CPU AND MEMORY"
  "KERNEL PARAMETERS"
  "DISK AND FILESYSTEM"
  "NETWORK CONFIGURATION"
  "OPEN FILE DESCRIPTORS"
  "JVM CONFIGURATION"
  "KAFKA BROKER CONFIGURATION"
  "REPLICATION AND PARTITION HEALTH"
  "NETWORK LATENCY"
)

# Extract a named section from a report file into a temp file
# Sections are delimited by lines starting with "==="
extract_section() {
  local report="$1"
  local section="$2"
  local outfile="$3"
  awk -v sec="$section" '
    /^=+/ { in_sec = (toupper($0) ~ toupper(sec)); next }
    in_sec { print }
  ' "$report" >"$outfile"
}

diff_count=0
for section in "${SECTIONS[@]}"; do
  section_slug=$(echo "$section" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
  diff_file="$WORKDIR/diffs/${section_slug}.diff"

  # Collect per-node section extracts
  declare -a section_files=()
  for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
    name="${REACHABLE_NAMES[$i]}"
    report="${REPORT_FILES[$i]}"
    extract_file="$WORKDIR/raw/${name}.${section_slug}.txt"
    if [[ -f "$report" ]]; then
      extract_section "$report" "$section" "$extract_file"
    else
      touch "$extract_file"
    fi
    section_files+=("$extract_file")
  done

  # Compare all extracts against the first
  ref="${section_files[0]}"
  has_diff=false
  {
    echo "# Section: $section"
    echo "# Reference node: ${REACHABLE_NAMES[0]}"
    echo ""
    for i in $(seq 1 $((REACHABLE_COUNT - 1))); do
      cmp_node="${REACHABLE_NAMES[$i]}"
      cmp_file="${section_files[$i]}"
      if ! diff -q "$ref" "$cmp_file" &>/dev/null; then
        has_diff=true
        echo "## ${REACHABLE_NAMES[0]} vs $cmp_node"
        diff -u --label "${REACHABLE_NAMES[0]}" --label "$cmp_node" "$ref" "$cmp_file" || true
        echo ""
      fi
    done
  } >"$diff_file"

  if $has_diff; then
    log_warn "Drift detected in section: $section → $diff_file"
    diff_count=$((diff_count + 1))
  else
    log_ok "No drift in section: $section"
  fi
done

echo ""
if [[ $diff_count -eq 0 ]]; then
  log_ok "All sections identical across nodes."
else
  log_warn "$diff_count section(s) with cross-node drift."
fi

# ─── Phase 4: Findings report ─────────────────────────────────────────────────
log_phase "Phase 4: Generating FINDINGS.md"

FINDINGS="$WORKDIR/FINDINGS.md"
NOW=$(date '+%Y-%m-%d %H:%M:%S %Z')

# Helper: grep a value from all node reports for a key pattern
# Outputs a markdown table row per node
grep_all_nodes() {
  local pattern="$1"
  local label="$2"
  for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
    name="${REACHABLE_NAMES[$i]}"
    report="${REPORT_FILES[$i]}"
    val=$(grep -iE "$pattern" "$report" 2>/dev/null | head -1 | sed 's/^[[:space:]]*//' || echo "(not found)")
    echo "| $name | $label | $val |"
  done
}

# ── Collect key metrics per node into associative-style variables ─────────────
declare -A SWAPPINESS THP NOATIME IOSCHEDULER ENA_EXCEEDED \
            FD_LIMIT JVM_HEAP GC_ALGO NUM_IO_THREADS NUM_NET_THREADS \
            SOCKET_BUF UNCLEAN MIR UNDER_REP

collect_metric() {
  local node_name="$1"
  local report="$2"
  SWAPPINESS["$node_name"]=$(grep -iE 'vm\.swappiness\s*=' "$report" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  THP["$node_name"]=$(grep -iE 'transparent.*hugepages|thp' "$report" 2>/dev/null | grep -oE '\[always\]|\[madvise\]|\[never\]' | head -1 || echo "?")
  NOATIME["$node_name"]=$(grep -iE 'noatime' "$report" 2>/dev/null | head -1 || echo "not found")
  IOSCHEDULER["$node_name"]=$(grep -iE 'i.?o.?scheduler|queue/scheduler' "$report" 2>/dev/null | head -1 || echo "?")
  ENA_EXCEEDED["$node_name"]=$(grep -iE 'allowance_exceeded' "$report" 2>/dev/null | grep -v '^0$' | head -1 || echo "0")
  FD_LIMIT["$node_name"]=$(grep -iE 'file.*descriptor|open.*files|nofile' "$report" 2>/dev/null | grep -oE '[0-9]+' | sort -n | tail -1 || echo "?")
  JVM_HEAP["$node_name"]=$(grep -iE '\-Xmx|\-Xms' "$report" 2>/dev/null | grep -oE '[0-9]+[gGmM]' | head -1 || echo "?")
  GC_ALGO["$node_name"]=$(grep -iE 'UseG1GC|UseZGC|UseShenandoahGC|UseCMS|UseParallelGC' "$report" 2>/dev/null | grep -oE 'UseG1GC|UseZGC|UseShenandoahGC|UseCMS|UseParallelGC' | head -1 || echo "?")
  NUM_IO_THREADS["$node_name"]=$(grep -iE 'num\.io\.threads' "$report" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  NUM_NET_THREADS["$node_name"]=$(grep -iE 'num\.network\.threads' "$report" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  SOCKET_BUF["$node_name"]=$(grep -iE 'socket\.send\.buffer|socket\.receive\.buffer' "$report" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  UNCLEAN["$node_name"]=$(grep -iE 'unclean\.leader\.election\.enable' "$report" 2>/dev/null | grep -oiE 'true|false' | head -1 || echo "?")
  MIR["$node_name"]=$(grep -iE 'min\.insync\.replicas' "$report" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "?")
  UNDER_REP["$node_name"]=$(grep -iE 'under.replicated' "$report" 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "0")
}

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  collect_metric "${REACHABLE_NAMES[$i]}" "${REPORT_FILES[$i]}"
done

# ── Red flag detection ────────────────────────────────────────────────────────
declare -a RED_FLAGS
for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  n="${REACHABLE_NAMES[$i]}"

  sw="${SWAPPINESS[$n]}"
  [[ "$sw" =~ ^[0-9]+$ ]] && [[ $sw -gt 1 ]] && \
    RED_FLAGS+=("**$n**: vm.swappiness=$sw (should be ≤1)")

  thp="${THP[$n]}"
  [[ "$thp" == "[always]" ]] && \
    RED_FLAGS+=("**$n**: THP = [always] (should be [never])")

  na="${NOATIME[$n]}"
  [[ "$na" == "not found" ]] && \
    RED_FLAGS+=("**$n**: noatime not found on Kafka log dir mount")

  fd="${FD_LIMIT[$n]}"
  [[ "$fd" =~ ^[0-9]+$ ]] && [[ $fd -lt 100000 ]] && \
    RED_FLAGS+=("**$n**: open file descriptor limit=$fd (should be ≥100000)")

  heap="${JVM_HEAP[$n]}"
  heap_gb=0
  if [[ "$heap" =~ ^([0-9]+)[gG]$ ]]; then
    heap_gb="${BASH_REMATCH[1]}"
  elif [[ "$heap" =~ ^([0-9]+)[mM]$ ]]; then
    heap_gb=$(( BASH_REMATCH[1] / 1024 ))
  fi
  [[ $heap_gb -gt 6 ]] && \
    RED_FLAGS+=("**$n**: JVM heap=${heap} (>6 GB risks GC pauses; use 4–6 GB with G1/ZGC)")

  gc="${GC_ALGO[$n]}"
  [[ -n "$gc" && "$gc" != "UseG1GC" && "$gc" != "UseZGC" ]] && \
    RED_FLAGS+=("**$n**: GC algorithm=${gc} (prefer G1GC or ZGC for Kafka brokers)")

  io="${NUM_IO_THREADS[$n]}"
  # We don't know vCPU count here, but flag if obviously low
  [[ "$io" =~ ^[0-9]+$ ]] && [[ $io -lt 8 ]] && \
    RED_FLAGS+=("**$n**: num.io.threads=$io (typically should match vCPU count)")

  nt="${NUM_NET_THREADS[$n]}"
  [[ "$nt" =~ ^[0-9]+$ ]] && [[ $nt -lt 8 ]] && \
    RED_FLAGS+=("**$n**: num.network.threads=$nt (should be ≥8 on busy brokers)")

  sb="${SOCKET_BUF[$n]}"
  [[ "$sb" =~ ^[0-9]+$ ]] && [[ $sb -le 102400 ]] && \
    RED_FLAGS+=("**$n**: socket buffers at default ($sb) — increase to 1–4 MB for high throughput")

  uc="${UNCLEAN[$n]}"
  [[ "$uc" == "true" ]] && \
    RED_FLAGS+=("**$n**: unclean.leader.election.enable=true (risk of data loss)")

  mir="${MIR[$n]}"
  [[ "$mir" =~ ^[0-9]+$ ]] && [[ $mir -lt 2 ]] && \
    RED_FLAGS+=("**$n**: min.insync.replicas=$mir (should be 2 with RF=3)")

  ur="${UNDER_REP[$n]}"
  [[ "$ur" =~ ^[0-9]+$ ]] && [[ $ur -gt 0 ]] && \
    RED_FLAGS+=("**$n**: $ur under-replicated partition(s) detected")

  ena="${ENA_EXCEEDED[$n]}"
  [[ "$ena" != "0" && -n "$ena" && "$ena" != "not found" ]] && \
    RED_FLAGS+=("**$n**: ENA *_allowance_exceeded counters non-zero: $ena")
done

# ── Write FINDINGS.md ─────────────────────────────────────────────────────────
RED_FLAG_COUNT="${#RED_FLAGS[@]}"

{
cat <<HEADER
# Kafka Latency Audit — Findings

**Generated:** $NOW
**Nodes audited:** $REACHABLE_COUNT / $NODE_COUNT
**Dispatch mode:** ${DISPATCH_MODE^^}
**Red flags found:** $RED_FLAG_COUNT
**Sections with drift:** $diff_count

---

## 1. Executive Summary

HEADER

# Top 5 highest-impact issues
if [[ $RED_FLAG_COUNT -eq 0 ]]; then
  echo "No latency red flags detected across audited nodes. All checked settings appear within recommended ranges."
else
  echo "Top issues by impact (see Section 3 for full list):"
  echo ""
  count=0
  for flag in "${RED_FLAGS[@]}"; do
    [[ $count -ge 5 ]] && break
    echo "- $flag"
    count=$((count + 1))
  done
  if [[ $RED_FLAG_COUNT -gt 5 ]]; then
    echo ""
    echo "_...and $((RED_FLAG_COUNT - 5)) additional flag(s) — see Section 3._"
  fi
fi

cat <<'DRIFT_HDR'

---

## 2. Drift Across Nodes

Settings that **differ between nodes** are listed here. Identical settings are omitted.

DRIFT_HDR

# Build drift table from collected metrics
{
  echo "| Setting | $(IFS=' | '; echo "${REACHABLE_NAMES[*]}") |"
  echo "|---------|$(printf -- '--------|%.0s' $(seq 1 $REACHABLE_COUNT))"

  metrics=(SWAPPINESS THP FD_LIMIT JVM_HEAP GC_ALGO NUM_IO_THREADS NUM_NET_THREADS SOCKET_BUF UNCLEAN MIR UNDER_REP)
  metric_labels=("vm.swappiness" "THP" "fd-limit" "JVM heap" "GC" "num.io.threads" "num.network.threads" "socket-buffers" "unclean-leader-election" "min.insync.replicas" "under-replicated-partitions")

  for idx in "${!metrics[@]}"; do
    metric="${metrics[$idx]}"
    label="${metric_labels[$idx]}"
    declare -n ref_map="$metric"

    # Collect all unique values
    declare -a vals=()
    for n in "${REACHABLE_NAMES[@]}"; do
      vals+=("${ref_map[$n]:-?}")
    done

    # Check if all identical
    first="${vals[0]}"
    all_same=true
    for v in "${vals[@]}"; do
      [[ "$v" != "$first" ]] && all_same=false
    done
    $all_same && continue

    row="| $label |"
    for v in "${vals[@]}"; do
      row+=" $v |"
    done
    echo "$row"
  done
} 2>/dev/null

if [[ $diff_count -eq 0 ]]; then
  echo ""
  echo "_No configuration drift detected across nodes._"
fi

cat <<'FLAGS_HDR'

---

## 3. Latency Red Flags

FLAGS_HDR

if [[ $RED_FLAG_COUNT -eq 0 ]]; then
  echo "No red flags detected. All checked settings are within recommended ranges."
else
  for flag in "${RED_FLAGS[@]}"; do
    echo "- $flag"
  done
fi

cat <<'STEPS_HDR'

---

## 4. Recommended Next Steps

_Ordered by expected latency impact (highest first):_

STEPS_HDR

# Generate recommendations based on detected flags
step=1
for flag in "${RED_FLAGS[@]}"; do
  case "$flag" in
    *THP*"[always]"*)
      echo "$step. **Disable Transparent Huge Pages:** \`echo never > /sys/kernel/mm/transparent_hugepage/enabled\` and persist in \`/etc/rc.local\` or a systemd unit. THP causes multi-millisecond GC pauses."
      step=$((step + 1))
      ;;
    *swappiness*)
      echo "$step. **Reduce vm.swappiness:** \`sysctl -w vm.swappiness=1\` (not 0 — prevents OOM killer; not >1 — prevents latency spikes from swap). Persist in \`/etc/sysctl.d/99-kafka.conf\`."
      step=$((step + 1))
      ;;
    *noatime*)
      echo "$step. **Add noatime to Kafka log dir mount:** Edit \`/etc/fstab\`, add \`noatime\` to the mount options for the Kafka log directory (typically \`/data/kafka\`). Eliminates a metadata write per read."
      step=$((step + 1))
      ;;
    *socket*default*)
      echo "$step. **Increase socket buffers:** Set \`socket.send.buffer.bytes=4194304\` and \`socket.receive.buffer.bytes=4194304\` in \`server.properties\`. Also set OS-level \`net.core.rmem_max\` and \`wmem_max\` to match."
      step=$((step + 1))
      ;;
    *num.io.threads*)
      echo "$step. **Increase num.io.threads:** Set to at least the number of vCPUs (i3.4xlarge = 16). More I/O threads reduces replication fetch queuing latency."
      step=$((step + 1))
      ;;
    *num.network.threads*)
      echo "$step. **Increase num.network.threads:** Set to ≥8. This controls the request processor thread pool. Low values create a bottleneck for producer/consumer connections."
      step=$((step + 1))
      ;;
    *JVM*heap*">"*)
      echo "$step. **Reduce JVM heap:** Target 4–6 GB with G1GC (\`-Xmx6g -Xms6g -XX:+UseG1GC\`). Heap >6 GB dramatically increases GC stop-the-world pause duration."
      step=$((step + 1))
      ;;
    *GC*algorithm*)
      echo "$step. **Switch GC algorithm:** Use \`-XX:+UseG1GC\` (Java 8–16) or \`-XX:+UseZGC\` (Java 17+). Avoid CMS (deprecated) and Parallel GC for latency-sensitive workloads."
      step=$((step + 1))
      ;;
    *unclean.leader.election*true*)
      echo "$step. **Disable unclean leader election:** Set \`unclean.leader.election.enable=false\` in broker config. This prevents data loss during partition leader transitions."
      step=$((step + 1))
      ;;
    *min.insync.replicas*)
      echo "$step. **Increase min.insync.replicas:** Set to 2 with RF=3. This ensures durability — without it, a single broker outage can cause acknowledged writes to be lost."
      step=$((step + 1))
      ;;
    *under-replicated*)
      echo "$step. **Investigate under-replicated partitions:** Run \`kafka-topics.sh --describe --under-replicated-partitions\`. Common causes: broker GC pauses, network bandwidth saturation, or a recently restarted broker still catching up."
      step=$((step + 1))
      ;;
    *ENA*allowance_exceeded*)
      echo "$step. **Investigate ENA network allowance exceeded:** Non-zero counters indicate the instance is hitting EC2 network bandwidth limits. Consider upgrading instance type or reducing replication fan-out. Run \`ethtool -S <iface> | grep allowance\` to monitor live."
      step=$((step + 1))
      ;;
    *fd-limit*)
      echo "$step. **Increase file descriptor limit:** Set \`nofile 131072\` in \`/etc/security/limits.d/kafka.conf\` (both hard and soft). Kafka opens one file per partition per segment — low limits cause connection errors under load."
      step=$((step + 1))
      ;;
  esac
done

if [[ $step -eq 1 ]]; then
  echo "No immediate fixes required. Run active probes (Phase 5) to establish a latency baseline."
fi

BOOTSTRAP_ARG="${BOOTSTRAP:-<HOST>:9092}"

cat <<PROBES_HDR

---

## 5. Active Probe Plan

Run these after a **quiet window** (no active producers/consumers if possible).
Confirm with \`run probes\` to have the script execute them automatically.

### fio — Disk latency (run on ALL nodes in parallel)

\`\`\`bash
# On each broker node:
sudo bash /tmp/kafka-latency-audit.sh --fio
\`\`\`

Flags: p99 write latency > 5 ms on any node.

### producer-perf-test — End-to-end Kafka latency (run on ONE node only)

\`\`\`bash
# On broker1 only (not parallel — parallel runs skew results):
sudo bash /tmp/kafka-latency-audit.sh --perf ${BOOTSTRAP_ARG}
\`\`\`

Flags: p99 end-to-end > 50 ms.

### Quiet-window guidance

- Run fio during off-peak hours (avoid peak CDC throughput windows)
- producer-perf-test creates a temporary topic \`__perf-test\` — confirm it is deleted after the run
- Review Control Center lag dashboards before and after to confirm no connector disruption

---

## 6. Drift Diff Files

PROBES_HDR

for section in "${SECTIONS[@]}"; do
  section_slug=$(echo "$section" | tr ' ' '_' | tr '[:upper:]' '[:lower:]')
  diff_file="diffs/${section_slug}.diff"
  echo "- [\`$diff_file\`]($diff_file) — $section"
done

cat <<FOOTER

---

## 7. Raw Reports

FOOTER

for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
  name="${REACHABLE_NAMES[$i]}"
  echo "- [\`raw/${name}-audit.txt\`](raw/${name}-audit.txt) — ${NODE_LABELS[$i]}"
  echo "- [\`raw/${name}.log\`](raw/${name}.log) — stdout/stderr from audit run"
done

} >"$FINDINGS"

log_ok "FINDINGS.md written: $FINDINGS"

# ─── Phase 5: Active probes (optional) ────────────────────────────────────────
if $RUN_PROBES; then
  log_phase "Phase 5: Active probes (--probes flag set)"

  # fio in parallel on all nodes
  log_info "Running --fio on all $REACHABLE_COUNT nodes in parallel..."
  declare -a FIO_PIDS
  for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
    name="${REACHABLE_NAMES[$i]}"
    addr="${REACHABLE_ADDRS[$i]}"
    fio_log="$WORKDIR/raw/${name}.fio.log"
    (
      run_remote "$name" "$addr" \
        "sudo bash /tmp/kafka-latency-audit.sh --fio 2>&1" \
        "$fio_log" 300
      # Pull updated report
      run_remote "$name" "$addr" \
        "ls /tmp/kafka-latency-audit-*.txt 2>/dev/null | sort | tail -1" \
        "$fio_log.list" 20 || true
      remote_report=$(grep '/tmp/kafka-latency-audit-' "$fio_log.list" 2>/dev/null | tail -1 | tr -d '[:space:]')
      if [[ -n "$remote_report" ]]; then
        scp_from_node "$addr" "$remote_report" "$WORKDIR/raw/${name}-fio-audit.txt" "$fio_log" || true
      fi
    ) &
    FIO_PIDS+=($!)
  done
  for i in "${!FIO_PIDS[@]}"; do
    name="${REACHABLE_NAMES[$i]}"
    if wait "${FIO_PIDS[$i]}"; then
      log_ok "$name: fio complete"
    else
      log_warn "$name: fio had errors"
    fi
  done

  # producer-perf on first broker only
  if [[ -n "$BOOTSTRAP" ]]; then
    log_info "Running --perf on ${REACHABLE_NAMES[0]} (single-node only)..."
    perf_log="$WORKDIR/raw/${REACHABLE_NAMES[0]}.perf.log"
    run_remote "${REACHABLE_NAMES[0]}" "${REACHABLE_ADDRS[0]}" \
      "sudo bash /tmp/kafka-latency-audit.sh --perf $BOOTSTRAP 2>&1" \
      "$perf_log" 300 && log_ok "producer-perf complete" || log_warn "producer-perf had errors"
  else
    log_warn "BOOTSTRAP not set — skipping producer-perf-test."
  fi

  # Append probe results section to FINDINGS.md
  {
    echo ""
    echo "---"
    echo ""
    echo "## Probe Results"
    echo ""
    echo "### fio — Disk Write Latency"
    echo ""
    echo "| Node | p50 | p99 | p99.9 | Flag |"
    echo "|------|-----|-----|-------|------|"
    for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
      name="${REACHABLE_NAMES[$i]}"
      fio_report="$WORKDIR/raw/${name}-fio-audit.txt"
      if [[ ! -f "$fio_report" ]]; then
        fio_report="$WORKDIR/raw/${name}.fio.log"
      fi
      p50=$(grep -iE 'lat.*p50|p50.*lat|50th' "$fio_report" 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*\s*(ms|us|ns)' | head -1 || echo "n/a")
      p99=$(grep -iE 'lat.*p99[^9]|p99[^9].*lat|99th' "$fio_report" 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*\s*(ms|us|ns)' | head -1 || echo "n/a")
      p999=$(grep -iE 'lat.*p99\.9|p99\.9.*lat|99\.9th' "$fio_report" 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*\s*(ms|us|ns)' | head -1 || echo "n/a")
      flag=""
      # Flag if p99 > 5ms (simple numeric check)
      p99_num=$(echo "$p99" | grep -oE '^[0-9]+\.?[0-9]*' || echo "0")
      p99_unit=$(echo "$p99" | grep -oE 'ms|us|ns' || echo "ms")
      p99_ms=$p99_num
      [[ "$p99_unit" == "us" ]] && p99_ms=$(echo "$p99_num / 1000" | bc 2>/dev/null || echo "0")
      [[ "$p99_unit" == "ns" ]] && p99_ms=$(echo "$p99_num / 1000000" | bc 2>/dev/null || echo "0")
      p99_ms_int=${p99_ms%.*}
      [[ "${p99_ms_int:-0}" -gt 5 ]] 2>/dev/null && flag="⚠ >5ms"
      echo "| $name | $p50 | $p99 | $p999 | $flag |"
    done

    if [[ -n "$BOOTSTRAP" ]]; then
      echo ""
      echo "### producer-perf-test — End-to-End Latency"
      echo ""
      perf_log="$WORKDIR/raw/${REACHABLE_NAMES[0]}.perf.log"
      echo "| Metric | Value | Flag |"
      echo "|--------|-------|------|"
      if [[ -f "$perf_log" ]]; then
        for pct in p50 p99 p99.9; do
          val=$(grep -iE "$pct" "$perf_log" 2>/dev/null | grep -oE '[0-9]+\.?[0-9]*\s*ms' | head -1 || echo "n/a")
          flag=""
          num=$(echo "$val" | grep -oE '^[0-9]+\.?[0-9]*' || echo "0")
          threshold=50; [[ "$pct" == "p50" ]] && threshold=10
          [[ "${num%.*}" -gt $threshold ]] 2>/dev/null && flag="⚠ >${threshold}ms"
          echo "| $pct | $val | $flag |"
        done
      else
        echo "| (all) | perf log not found | |"
      fi
    fi
  } >>"$FINDINGS"

  log_ok "Probe results appended to FINDINGS.md."
fi

# ─── Phase 6: Cleanup ─────────────────────────────────────────────────────────
if $DO_CLEANUP; then
  log_phase "Phase 6: Cleanup remote temp files"
  for i in $(seq 0 $((REACHABLE_COUNT - 1))); do
    name="${REACHABLE_NAMES[$i]}"
    addr="${REACHABLE_ADDRS[$i]}"
    cleanup_log="$WORKDIR/raw/${name}.cleanup.log"
    if run_remote "$name" "$addr" \
        "rm -f /tmp/kafka-latency-audit.sh /tmp/kafka-latency-audit-*.txt" \
        "$cleanup_log" 30; then
      log_ok "$name: cleaned up"
    else
      log_warn "$name: cleanup failed (see $cleanup_log)"
    fi
  done
fi

# ─── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                   Audit Complete                             ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Findings report:${NC} $(realpath "$FINDINGS")"
echo ""
echo -e "  TL;DR:"
if [[ $RED_FLAG_COUNT -eq 0 ]]; then
  echo -e "  • ${GREEN}No latency red flags found${NC} — cluster configuration is within recommended ranges."
else
  echo -e "  • ${RED}$RED_FLAG_COUNT latency red flag(s) detected${NC} — see Section 3 of FINDINGS.md."
fi
if [[ $diff_count -gt 0 ]]; then
  echo -e "  • ${YELLOW}$diff_count section(s) show configuration drift across nodes${NC} — drift diffs in $WORKDIR/diffs/"
else
  echo -e "  • ${GREEN}No configuration drift${NC} across audited nodes."
fi
if ! $RUN_PROBES; then
  echo -e "  • Active probes (fio + producer-perf) not yet run. Review FINDINGS.md Section 5, then rerun with ${BOLD}--probes${NC}."
fi
echo ""
